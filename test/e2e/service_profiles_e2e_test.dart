@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #204 end to end: data-driven `--use-*` profiles
/// (`~/.cube-sandbox/services.yaml`) + the generated `AGENTS.md` manual.
/// CLI wiring (exit codes, fail-fast listings, file:line errors, AGENTS.md
/// ensure/init seams) runs against the compiled binary without a kernel;
/// kernel truths (grant effective inside the sandbox, env overlay, key10
/// provenance) skip LOUDLY on hosts that refuse nested profile
/// application.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  late Directory tmp;
  late String proj;
  late String home;

  setUp(() async {
    final cacheRoot = Directory('${Directory.current.path}/.cache');
    if (!cacheRoot.existsSync()) cacheRoot.createSync(recursive: true);
    tmp = await cacheRoot.createTemp('cube-sandbox-e204-');
    await Directory('${tmp.path}/proj/.cube-sandbox').create(recursive: true);
    await Directory('${tmp.path}/home/.cube-sandbox').create(recursive: true);
    proj = Directory('${tmp.path}/proj').resolveSymbolicLinksSync();
    home = Directory('${tmp.path}/home').resolveSymbolicLinksSync();
    Directory('$home/agent').createSync();
    File('$proj/.cube-sandbox/codemie.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: codemie
spec:
  command: /usr/bin/true
  agentRoot: $home/agent
''');
  });

  tearDown(() async => tmp.delete(recursive: true));

  void writeServices({String extra = '', bool bad = false}) =>
      File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  demo:
    description: e2e scratch
    write: [~/scratch]
    env:
      SCRITCH_E2E: visible
${bad ? '  badprof:\n    oops-key: 1\n' : ''}$extra''');

  Map<String, String> env() => {'HOME': home};

  h.RunOut run(List<String> args) =>
      h.launchCubeSandbox(args, cwd: proj, env: env());

  group('AGENTS.md seams (no kernel)', () {
    test('AC1: fresh HOME + list creates the dot-dir and the manual', () {
      Directory('$home/.cube-sandbox').deleteSync();
      final r = run(['list']);
      expect(r.exit, 0, reason: r.stderr);
      final f = File('$home/.cube-sandbox/AGENTS.md');
      expect(f.existsSync(), isTrue, reason: 'manual must materialize');
      expect(f.readAsStringSync(), contains('cube-sandbox agent manual'));
    });

    test('AC2: second list is a no-op (content + mtime unchanged)', () {
      run(['list']);
      final f = File('$home/.cube-sandbox/AGENTS.md');
      final before = f.lastModifiedSync();
      final r = run(['list']);
      expect(r.exit, 0, reason: r.stderr);
      expect(f.lastModifiedSync(), before);
    });

    test('AC3: user-owned manual preserved, exactly one stderr notice', () {
      final f = File('$home/.cube-sandbox/AGENTS.md')
        ..writeAsStringSync('# mine\n');
      final r = run(['list']);
      expect(r.exit, 0, reason: r.stderr);
      expect(f.readAsStringSync(), '# mine\n', reason: 'never overwritten');
      expect(
        r.stderr.split('\n').where((l) => l.contains('init --force')),
        hasLength(1),
        reason: 'exactly one notice:\n${r.stderr}',
      );
    });

    test(
      'AC4: init --force replaces; plain init preserves a differing file',
      () {
        File('$home/.cube-sandbox/AGENTS.md').writeAsStringSync('# mine\n');
        final plain = run(['init']);
        expect(plain.exit, 0, reason: plain.stderr);
        expect(
          File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
          '# mine\n',
          reason: 'plain init never overwrites',
        );
        final forced = run(['init', '--force']);
        expect(forced.exit, 0, reason: forced.stderr);
        expect(
          File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
          contains('cube-sandbox agent manual'),
        );
      },
    );
  });

  group('services.yaml CLI wiring (no kernel)', () {
    test('AC12: unknown profile fails fast listing profiles + AGENTS.md', () {
      writeServices();
      final r = run(['show', '--use-nope', 'codemie']);
      expect(r.exit, 2);
      expect(r.stderr, contains('demo'), reason: 'discovered profiles listed');
      expect(r.stderr, contains('AGENTS.md'), reason: 'manual pointer');
    });

    test('AC13: malformed profile -> exit 2 naming file AND line', () {
      writeServices(bad: true);
      final r = run(['show', '--use-badprof', 'codemie']);
      expect(r.exit, 2);
      expect(
        r.stderr,
        matches(RegExp(r'services\.yaml:9:')),
        reason: 'file:line error:\n${r.stderr}',
      );
      expect(r.stderr, contains('unknown key'));
    });

    test('unknown id + missing file: exit 2, absence stated', () {
      final r = run(['show', '--use-nope', 'codemie']);
      expect(r.exit, 2);
      expect(r.stderr, contains('no services.yaml found'));
      expect(r.stderr, contains('catalog: github, gitlab, nvm, uv'));
    });

    test('built-in-only run never reads a malformed services.yaml (lazy)', () {
      File(
        '$home/.cube-sandbox/services.yaml',
      ).writeAsStringSync('not: [a, services, document\n');
      final r = run(['show', '--use-github', 'codemie']);
      expect(r.exit, 0, reason: 'lazy contract:\n${r.stderr}');
    });

    test('built-in catalog shadows a rogue services.yaml entry', () {
      writeServices(extra: '  github:\n    write: [/tmp/rogue-never]\n');
      final r = run(['show', '--use-github', 'codemie']);
      expect(r.exit, 0, reason: r.stderr);
      expect(r.stdout, contains('.config/gh'), reason: 'catalog grants');
      expect(
        r.stdout,
        isNot(contains('/tmp/rogue-never')),
        reason: 'shadowed entry is ignored',
      );
    });

    test('config profile appears in the banner use line', () {
      writeServices();
      final r = run(['show', '--use-demo', 'codemie']);
      expect(r.exit, 0, reason: r.stderr);
      expect(r.stdout, contains('use    : demo'));
      expect(r.stdout, contains('$home/scratch'));
    });

    test('AC11 (dry-run): union with --use-github lands in the sbpl text', () {
      writeServices();
      final union = run(['sbpl', '--use-demo', '--use-github', 'codemie']);
      expect(union.exit, 0, reason: union.stderr);
      expect(
        union.stdout,
        contains('(allow file-write* (subpath "$home/scratch")'),
        reason: 'profile grant',
      );
      expect(
        union.stdout,
        contains('(allow file-read* (subpath "$home/.config/gh")'),
        reason: 'built-in grant rides the same stage',
      );
    });

    test('grant change moves key10 (no stale profile can be reused)', () {
      writeServices();
      final one = run(['show', '--use-demo', 'codemie']);
      expect(one.exit, 0, reason: one.stderr);
      final keyOne = RegExp(
        r'profile ([0-9a-f]{10})',
      ).firstMatch(one.stdout)![1]!;
      File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  demo:
    description: e2e scratch
    write: [~/scratch2]
''');
      final two = run(['show', '--use-demo', 'codemie']);
      expect(two.exit, 0, reason: two.stderr);
      final keyTwo = RegExp(
        r'profile ([0-9a-f]{10})',
      ).firstMatch(two.stdout)![1]!;
      expect(keyTwo, isNot(keyOne));
    });
  });

  group('kernel flows (fail-closed on guard hosts)', () {
    test(
      'AC11/E2E: profile write grant effective inside the sandbox; '
      'union with --use-github; outside still denied',
      () {
        writeServices();
        Directory('$home/scratch').createSync();
        Directory('$home/outside').createSync();

        final granted = run([
          'launch',
          '--wait',
          '--use-demo',
          'codemie',
          '--',
          '/usr/bin/touch',
          '$home/scratch/created',
        ]);
        expect(granted.exit, 0, reason: granted.stderr);
        expect(File('$home/scratch/created').existsSync(), isTrue);

        // Union: profile grants + a built-in service grant compose.
        final union = run(['sbpl', '--use-demo', '--use-github', 'codemie']);
        expect(union.exit, 0, reason: union.stderr);
        expect(
          union.stdout,
          contains('(allow file-write* (subpath "$home/scratch")'),
        );
        expect(
          union.stdout,
          contains('(allow file-read* (subpath "$home/.config/gh")'),
        );

        // Outside the union: still denied.
        final denied = run([
          'launch',
          '--wait',
          '--use-demo',
          'codemie',
          '--',
          '/usr/bin/touch',
          '$home/outside/nope',
        ]);
        expect(denied.exit, isNot(0), reason: 'sibling dir stays denied');
        expect(File('$home/outside/nope').existsSync(), isFalse);
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'AC11b/E2E: profile env overlay reaches the confined command',
      () {
        writeServices();
        final r = run([
          'launch',
          '--wait',
          '--use-demo',
          'codemie',
          '--',
          '/bin/sh',
          '-c',
          'printf %s "\$SCRITCH_E2E"',
        ]);
        expect(r.exit, 0, reason: r.stderr);
        expect(r.stdout, contains('visible'));
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'AC14/E2E: a brand-new process uses a just-added profile — '
      'zero rebuild, pure file operation',
      () {
        writeServices();
        final first = run([
          'launch',
          '--wait',
          '--use-demo',
          'codemie',
          '--',
          '/usr/bin/true',
        ]);
        expect(first.exit, 0, reason: first.stderr);

        // "cat >>" a second profile: immediately usable, no reinstall.
        File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  demo:
    description: e2e scratch
    write: [~/scratch]
  second:
    write: [~/scratch]
''');
        Directory('$home/scratch').createSync();
        final second = run([
          'launch',
          '--wait',
          '--use-second',
          'codemie',
          '--',
          '/usr/bin/touch',
          '$home/scratch/second',
        ]);
        expect(second.exit, 0, reason: second.stderr);
        expect(File('$home/scratch/second').existsSync(), isTrue);
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E2E: services.yaml change moves key10 and the .src stamp names it',
      () {
        writeServices();
        final one = run(['launch', '--wait', '--use-demo', 'codemie']);
        expect(one.exit, 0, reason: one.stderr);
        final keyOne = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(one.stderr)![1]!;
        final srcOne = File(
          '$proj/.cube-sandbox/cache/harness-$keyOne.src',
        ).readAsStringSync();
        expect(srcOne, contains('services.demo'));
        expect(srcOne, contains('SCRITCH_E2E'), reason: 'env KEYS, not values');
        expect(srcOne, isNot(contains('visible')), reason: 'values never');

        // Changed grant => new key, fresh stage (cache truthfulness).
        File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  demo:
    description: e2e scratch
    write: [~/scratch2]
''');
        final two = run(['launch', '--wait', '--use-demo', 'codemie']);
        expect(two.exit, 0, reason: two.stderr);
        final keyTwo = RegExp(
          r'profile ([0-9a-f]{10})',
        ).firstMatch(two.stderr)![1]!;
        expect(keyTwo, isNot(keyOne), reason: 'grant change => new key10');
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );

    test(
      'E10: blocklisted profile write rejected; read honored + LOUD',
      () {
        File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  danger:
    write: [~/.gnupg]
''');
        final w = run(['launch', '--wait', '--use-danger', 'codemie']);
        expect(w.exit, 2, reason: 'writes to ~/.gnupg are never grantable');
        expect(w.stderr, contains('ungrantable'));

        File('$home/.cube-sandbox/services.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
services:
  danger:
    read: [~/.gnupg]
''');
        Directory('$home/.gnupg').createSync();
        File('$home/.gnupg/k.txt').writeAsStringSync('sec');
        final r = run([
          'launch',
          '--wait',
          '--use-danger',
          'codemie',
          '--',
          '/bin/cat',
          '$home/.gnupg/k.txt',
        ]);
        expect(r.exit, 0, reason: r.stderr);
        expect(r.stderr, contains('blocklisted read path'));
        expect(r.stdout, contains('sec'), reason: 'override honored');
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
