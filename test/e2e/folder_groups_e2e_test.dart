@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #101 end to end: `--folders` per-run folder groups. CLI wiring
/// (exit codes, banner, sbpl) runs against the compiled binary without a
/// kernel; the kernel truths (grant effective inside the sandbox, deny
/// outside it) skip LOUDLY on hosts that refuse nested profile
/// application.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  late Directory tmp;
  late String proj;
  late String home;

  setUp(() async {
    tmp = await Directory(
      '${Directory.current.path}/.cache',
    ).createTemp('cube-sandbox-e101-');
    await Directory('${tmp.path}/proj/.cube-sandbox').create(recursive: true);
    await Directory('${tmp.path}/home/.cube-sandbox').create(recursive: true);
    proj = Directory('${tmp.path}/proj').resolveSymbolicLinksSync();
    home = Directory('${tmp.path}/home').resolveSymbolicLinksSync();
    File('$proj/.cube-sandbox/codemie.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: codemie
spec:
  command: /bin/echo
  agentRoot: ~/.pi/agent
  widenToDotParent: true
  network: open
''');
  });

  tearDown(() async => tmp.delete(recursive: true));

  void writeGroups({bool danger = false}) =>
      File('$home/.cube-sandbox/folders.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
groups:
  projx:
    write: [~/data/projx]
    read: [~/data/notes]
  projy:
    write: [~/data/projy]
${danger ? '  danger:\n    read: [~/.gnupg]\n' : ''}''');

  Map<String, String> env() => {'HOME': home};

  h.RunOut run(List<String> args) =>
      h.launchCubeSandbox(args, cwd: proj, env: env());

  group('CLI wiring (no kernel)', () {
    test('AC9/E16: show renders the widened grants; sbpl prints them', () {
      writeGroups();
      final show = run(['show', '--folders', 'projx', 'codemie']);
      expect(show.exit, 0, reason: show.stderr);
      expect(show.stdout, contains('$home/data/projx'), reason: 'rw line');
      expect(show.stdout, contains('$home/data/notes'), reason: 'ro line');

      final sbpl = run(['sbpl', '--folders', 'projx', 'codemie']);
      expect(sbpl.exit, 0, reason: sbpl.stderr);
      expect(
        sbpl.stdout,
        contains('(allow file-write* (subpath "$home/data/projx")'),
      );
    });

    test('E1: unknown group -> exit 2 naming the group AND the file', () {
      writeGroups();
      final r = run(['show', '--folders', 'nope', 'codemie']);
      expect(r.exit, 2);
      expect(r.stderr, contains('nope'));
      expect(r.stderr, contains('folders.yaml'));
    });

    test('E2: flag used + file missing -> exit 2 naming the path', () {
      final r = run(['show', '--folders', 'projx', 'codemie']);
      expect(r.exit, 2);
      expect(r.stderr, contains('folders.yaml'));
    });

    test(
      'E14: flag unused -> file never read (absent file is a clean run)',
      () {
        final r = run(['show', 'codemie']);
        expect(r.exit, 0, reason: r.stderr);
      },
    );

    test('AC12/E3/E4/E5: malformed tokens -> usage 64', () {
      writeGroups();
      for (final token in ['', 'projx,', 'projx, projy', 'PROJX']) {
        final r = run(['show', '--folders', token, 'codemie']);
        expect(r.exit, 64, reason: 'token "$token": ${r.stderr}');
      }
    });

    test('AC3: probe rejects a bad selection before any kernel contact', () {
      writeGroups();
      final r = run(['probe', '--folders', 'nope', 'codemie']);
      expect(r.exit, 2);
      expect(r.stderr, contains('nope'));
    });
  });

  group('kernel flows (fail-closed on guard hosts)', () {
    test(
      'E2E-1: group write grant effective inside the sandbox; write outside '
      'the granted set still DENIED; granted read readable; key10 moves',
      () {
        writeGroups();
        for (final d in ['data/projx', 'data/notes', 'data/other']) {
          Directory('$home/$d').createSync(recursive: true);
        }
        File('$home/data/notes/note.txt').writeAsStringSync('note-content');

        final plain = run(['launch', '--wait', 'codemie', '--', '/bin/true']);
        expect(plain.exit, 0, reason: plain.stderr);
        final keyPlain = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(plain.stderr)![1]!;

        // RW grant WORKS inside the sandbox.
        final granted = run([
          'launch',
          '--wait',
          '--folders',
          'projx',
          'codemie',
          '--',
          '/usr/bin/touch',
          '$home/data/projx/created',
        ]);
        expect(granted.exit, 0, reason: granted.stderr);
        expect(File('$home/data/projx/created').existsSync(), isTrue);
        expect(
          granted.stderr,
          contains('$home/data/projx'),
          reason: 'banner rw',
        );
        final keyGranted = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(granted.stderr)![1]!;
        expect(keyGranted, isNot(keyPlain), reason: 'selection => new key10');

        // Write OUTSIDE the granted set is still DENIED.
        final denied = run([
          'launch',
          '--wait',
          '--folders',
          'projx',
          'codemie',
          '--',
          '/usr/bin/touch',
          '$home/data/other/nope',
        ]);
        expect(denied.exit, isNot(0), reason: 'sibling dir stays denied');
        expect(File('$home/data/other/nope').existsSync(), isFalse);

        // Granted read path is readable.
        final read = run([
          'launch',
          '--wait',
          '--folders',
          'projx',
          'codemie',
          '--',
          '/bin/cat',
          '$home/data/notes/note.txt',
        ]);
        expect(read.exit, 0, reason: read.stderr);
        expect(read.stdout, contains('note-content'));

        // Selection change: new key, fresh stage, .src names group + entry.
        final other = run([
          'launch',
          '--wait',
          '--folders',
          'projy',
          'codemie',
          '--',
          '/bin/true',
        ]);
        expect(other.exit, 0, reason: other.stderr);
        final keyOther = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(other.stderr)![1]!;
        expect(keyOther, isNot(keyGranted));
        final src = File(
          '$proj/.cube-sandbox/cache/harness-$keyOther.src',
        ).readAsStringSync();
        expect(src, contains('projy'));
        expect(src, contains('$home/data/projy'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E2E-2/E9: blocklisted read in a selected group honored + LOUD',
      () {
        writeGroups(danger: true);
        Directory('$home/.gnupg').createSync(recursive: true);
        File('$home/.gnupg/k.txt').writeAsStringSync('sec');

        final launch = run([
          'launch',
          '--wait',
          '--folders',
          'danger',
          'codemie',
          '--',
          '/bin/true',
        ]);
        expect(launch.exit, 0, reason: launch.stderr);
        expect(launch.stderr, contains('blocklisted read path'));

        final cat = run([
          'launch',
          '--wait',
          '--folders',
          'danger',
          'codemie',
          '--',
          '/bin/cat',
          '$home/.gnupg/k.txt',
        ]);
        expect(cat.exit, 0, reason: cat.stderr);
        expect(cat.stdout, contains('sec'), reason: 'grant honored');
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E8: blocklisted write in a selected group -> exit 2, nothing runs',
      () {
        File('$home/.cube-sandbox/folders.yaml').writeAsStringSync(
          'apiVersion: cube-sandbox/v1\ngroups:\n  danger:\n'
          '    write: [~/.gnupg]\n',
        );
        final r = run(['launch', '--wait', '--folders', 'danger', 'codemie']);
        expect(r.exit, 2);
        expect(r.stderr, contains('ungrantable'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E13: post-profile --folders is the harness argv, never ours',
      () {
        writeGroups();
        final r = run([
          'launch',
          '--wait',
          'codemie',
          '/bin/echo',
          '--folders',
          'projx',
        ]);
        expect(r.exit, 0, reason: r.stderr);
        expect(r.stdout, contains('--folders projx'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
