@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #69 — cache correctness end to end: a harness profile is rebuilt
/// whenever its configuration changes; same-stem shadowing is LOUD; the
/// cache has a clean command; corrupt/unreadable cache never crashes and
/// never runs unconfined. Kernel-needing tests skip with an explicit
/// reason on hosts that deny nested profile application.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  late Directory tmp;
  late String proj;
  late String home;

  // Directory.current inside the spawned binary reports the kernel's
  // /private/var spelling of system-temp paths; path assertions compare
  // against THESE (HOME-derived paths keep the env spelling instead).

  setUp(() async {
    // The fixture home must sit OUTSIDE the unconditional realpath($TMPDIR)
    // rw grant (runtime.dart E2) — under systemTemp even the stale narrow
    // profile authorizes the reporter's credential write, so E2E-1's
    // denial can never trigger on a real kernel. Package .cache/ is
    // gitignored and outside $TMPDIR on dev hosts and CI.
    tmp = await Directory(
      '${Directory.current.path}/.cache',
    ).createTemp('cube-sandbox-e69-');
    await Directory('${tmp.path}/proj/.cube-sandbox').create(recursive: true);
    await Directory('${tmp.path}/home/.cube-sandbox').create(recursive: true);
    proj = Directory('${tmp.path}/proj').resolveSymbolicLinksSync();
    home = Directory('${tmp.path}/home').resolveSymbolicLinksSync();
    // Kernel spelling is also the env spelling now; the guard below keeps
    // the fixture outside the grant if anyone moves it back.
    final tmpGrant = Directory(
      Directory.systemTemp.path,
    ).resolveSymbolicLinksSync();
    expect(
      home.startsWith(tmpGrant),
      isFalse,
      reason: 'fixture home must sit outside the unconditional \$TMPDIR grant',
    );
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  String manifest({required bool wide}) =>
      '''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: codemie
spec:
  command: /bin/echo
  agentRoot: ~/.pi/agent
  widenToDotParent: true
  extraRead: ${wide ? '[]' : '[~/.codemie]'}
  extraWrite: ${wide ? '[~/.codemie, ~/.pi/agent]' : '[~/.pi/agent]'}
  network: open
''';

  Map<String, String> env() => {'HOME': home};

  /// The stderr banner of one launch (profile key10 line included).
  h.RunOut launch(List<String> args) =>
      h.launchCubeSandbox(['launch', ...args], cwd: proj, env: env());

  group('clean command (AC3)', () {
    test('removes planted stale profiles + provenance, keeps manifests', () {
      final cachePath = '$proj/.cube-sandbox/cache';
      Directory(cachePath).createSync(recursive: true);
      File('$cachePath/harness-ccf00c25c5.sb').writeAsStringSync('stale\n');
      File(
        '$cachePath/harness-ccf00c25c5.src',
      ).writeAsStringSync('dead  old\n');
      File('$cachePath/harness-abc0000000.sb').writeAsStringSync('old\n');
      File('$cachePath/.gitignore').writeAsStringSync('*\n');
      File(
        '$proj/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: false));

      final r = h.launchCubeSandbox(['clean'], cwd: proj);
      expect(r.exit, 0, reason: r.stderr);
      expect(r.stdout, contains('cleaned'));
      expect(Directory(cachePath).existsSync(), isFalse);
      expect(File('$proj/.cube-sandbox/codemie.yaml').existsSync(), isTrue);
    });

    test('idempotent: nothing to clean is exit 0', () {
      final r = h.launchCubeSandbox(['clean'], cwd: proj);
      expect(r.exit, 0, reason: r.stderr);
      expect(r.stdout, contains('nothing to clean'));
    });

    test('usage documents clean + the between-sessions caveat (REG-2)', () {
      final r = h.launchCubeSandbox(['--help']);
      expect(r.stderr, contains('clean'));
      // Usage wraps lines; match the caveat across whitespace.
      expect(
        r.stderr,
        matches(RegExp('between\\s+sessions', caseSensitive: false)),
      );
    });
  });

  group('same-stem shadow loudness (AC4, E1/E2E-4) — show, no kernel', () {
    test(
      'project wins over a DIFFERING user copy: shadow warning names it',
      () {
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: true));
        File(
          '$home/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: false));
        final r = h.launchCubeSandbox(
          ['show', 'codemie'],
          cwd: proj,
          env: env(),
        );
        expect(r.exit, 0, reason: r.stderr);
        expect(r.stdout, contains('source : .cube-sandbox/ (project) ($proj'));
        expect(r.stdout, contains('shadowed'));
        // Shadow paths derive from env HOME (the /var spelling here).
        expect(r.stdout, contains('$home/.cube-sandbox/codemie.yaml'));
      },
    );

    test('--file wins over a DIFFERING project copy: loser named too', () {
      // --file beats the chain; the differing project copy is the shadow.
      File(
        '$proj/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: false));
      File(
        '$home/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: true));
      final r = h.launchCubeSandbox(
        ['show', 'codemie', '--file', '$home/.cube-sandbox/codemie.yaml'],
        cwd: proj,
        env: env(),
      );
      expect(r.exit, 0, reason: r.stderr);
      // --file echoes the path exactly as given (env HOME spelling).
      expect(r.stdout, contains('source : file ($home'));
      expect(r.stdout, contains('shadowed'));
      expect(r.stdout, contains('$proj/.cube-sandbox/codemie.yaml'));
    });

    test('identical copies are NOT shadow noise (negative control)', () {
      File(
        '$proj/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: true));
      File(
        '$home/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: true));
      final r = h.launchCubeSandbox(['show', 'codemie'], cwd: proj, env: env());
      expect(r.exit, 0, reason: r.stderr);
      expect(r.stdout, isNot(contains('shadowed')));
    });
  });

  group('banner truthfulness negative control (AC4, E2E-2) — no kernel', () {
    test('unchanged profile => byte-identical banner across runs', () {
      File(
        '$proj/.cube-sandbox/codemie.yaml',
      ).writeAsStringSync(manifest(wide: false));
      final a = h.launchCubeSandbox(['show', 'codemie'], cwd: proj, env: env());
      final b = h.launchCubeSandbox(['show', 'codemie'], cwd: proj, env: env());
      expect(a.exit, 0, reason: a.stderr);
      expect(b.stdout, a.stdout);
      expect(a.stdout, contains('⛨ codemie under cube-sandbox'));
    });
  });

  group('kernel flows (fail-closed on guard hosts)', () {
    test(
      'E2E-1 reporter scenario: extraWrite edit is effective on the next launch',
      () {
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: false));
        final credDir = Directory('$home/.codemie/credentials')
          ..createSync(recursive: true);
        final cred = '${credDir.path}/sso-abc123.enc';

        // First cached run: old grants — the credential write is DENIED.
        final first = launch([
          '--wait',
          'codemie',
          '--',
          '/usr/bin/touch',
          cred,
        ]);
        expect(
          first.exit,
          isNot(0),
          reason: 'stale grants must deny the write',
        );
        expect(File(cred).existsSync(), isFalse);
        final key1 = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(first.stderr)![1]!;

        // The manifest edit (extraWrite widened) — NEXT launch rebuilds.
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: true));
        final second = launch([
          '--wait',
          'codemie',
          '--',
          '/usr/bin/touch',
          cred,
        ]);
        expect(second.exit, 0, reason: second.stderr);
        final key2 = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(second.stderr)![1]!;
        expect(key2, isNot(key1), reason: 'source change => new key10');
        expect(second.stderr, contains('~/.codemie'));
        expect(
          File(cred).existsSync(),
          isTrue,
          reason: 'write succeeded confined',
        );
        // New key staged WITH its provenance stamp beside it.
        expect(
          File('$proj/.cube-sandbox/cache/harness-$key2.src').existsSync(),
          isTrue,
        );
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E2E-2 launch banner negative control: unchanged profile, identical banner',
      () {
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: false));
        final a = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        final b = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        expect(a.exit, 0, reason: a.stderr);
        expect(b.exit, 0, reason: b.stderr);
        expect(b.stderr, a.stderr);
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E2E-3 corrupt staged .sb is rebuilt on the next launch, still confined',
      () {
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: false));
        final first = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        expect(first.exit, 0, reason: first.stderr);
        final cache = Directory('$proj/.cube-sandbox/cache');
        final sb = cache.listSync().whereType<File>().firstWhere(
          (f) => f.path.endsWith('.sb'),
        );
        sb.writeAsStringSync('(garbage — not a profile');

        final second = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        expect(second.exit, 0, reason: second.stderr);
        expect(sb.readAsStringSync(), isNot(contains('garbage')));
        expect(sb.readAsStringSync(), contains('(version 1)'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E2E-5 emit-identical edit (description only): same key, provenance warning',
      () {
        File(
          '$proj/.cube-sandbox/codemie.yaml',
        ).writeAsStringSync(manifest(wide: false));
        final first = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        expect(first.exit, 0, reason: first.stderr);

        final edited = manifest(wide: false).replaceFirst(
          '  name: codemie\n',
          '  name: codemie\n  description: edited\n',
        );
        File('$proj/.cube-sandbox/codemie.yaml').writeAsStringSync(edited);
        final second = launch(['--wait', 'codemie', '--', '/usr/bin/true']);
        expect(second.exit, 0, reason: second.stderr);
        // Same key (emit identical) but the cache SAYS what happened.
        final key1 = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(first.stderr)![1]!;
        final key2 = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(second.stderr)![1]!;
        expect(key2, key1);
        expect(second.stderr, contains('provenance'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
