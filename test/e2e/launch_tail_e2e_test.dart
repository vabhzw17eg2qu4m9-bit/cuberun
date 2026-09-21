@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #43 — launch argv pass-through: everything after the profile
/// positional is the harness argv tail, forwarded verbatim; options must
/// precede the profile; the SBPL boundary is byte-identical with and
/// without a tail (I1); strict verbs stay strict; exit codes propagate
/// unchanged. Runs the compiled binary against the real sandbox-exec
/// backend with an echo-argv fake harness — skips loudly when the host
/// cannot apply profiles.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  late Directory tmp;
  late String proj;
  late String script;

  /// argv.sh: prints one arg per line; `__exit N` exits N; `__int` dies
  /// of SIGINT (exit 130 expected from the launcher).
  const scriptBody = '''
if [ "\$1" = "__exit" ]; then shift; exit "\$1"; fi
if [ "\$1" = "__int" ]; then kill -INT "\$\$"; sleep 5; fi
for a in "\$@"; do
  printf '%s\\n' "\$a"
done
''';

  setUp(() {
    if (hostGuard != null) {
      markTestSkipped(hostGuard);
      return;
    }
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-tail-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    proj = '${tmp.path}/proj';
    Directory('$proj/.cube-sandbox').createSync(recursive: true);
    script = '$proj/argv.sh';
    File(script).writeAsStringSync(scriptBody);
    Process.runSync('chmod', ['+x', script]);
    File('$proj/.cube-sandbox/argvp.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: argvp
spec:
  command:
    - $script
  agentRoot: $proj
''');
  });

  /// stdout lines of an echo-argv run = the exact harness argv tail
  /// (trailing newline dropped; empty-string tokens survive).
  List<String> argvTail(h.RunOut r) => r.stdout.split('\n')..removeLast();

  test(
    'E2E-2: the reporter command shape runs — launch <p> --resume <uuid>',
    () {
      final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
      addTearDown(() => home.deleteSync(recursive: true));
      final r = h.launchCubeSandbox(
        ['launch', 'argvp', '--resume', '01a0c37d-3bff-7521-95e5-ef1ff279da6b'],
        cwd: proj,
        env: {'HOME': home.path},
      );
      expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
      expect(r.stderr, isNot(contains('unknown option')));
      expect(r.stderr, isNot(contains('ConfigException')));
      expect(argvTail(r), ['--resume', '01a0c37d-3bff-7521-95e5-ef1ff279da6b']);
    },
  );

  test('E2E-1: tail reaches the harness verbatim, order preserved', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final r = h.launchCubeSandbox(
      ['launch', 'argvp', '--flag', 'value', 'plain', '-x'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
    expect(argvTail(r), ['--flag', 'value', 'plain', '-x']);
  });

  test('AC2: exact cube-sandbox spellings after the profile are tail', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final r = h.launchCubeSandbox(
      ['launch', 'argvp', '--file', 'x', '--yaml', 'y', '--use-github'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
    expect(r.stderr, isNot(contains('unknown option')));
    expect(argvTail(r), ['--file', 'x', '--yaml', 'y', '--use-github']);
  });

  test('E4: empty-string tail token is forwarded as-is', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final r = h.launchCubeSandbox(
      ['launch', 'argvp', '', '--end'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
    expect(argvTail(r), ['', '--end']);
  });

  test('E5: string spec.command becomes argv first, tail appends after', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    File('$proj/.cube-sandbox/strc.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: strc
spec:
  command: $script
  agentRoot: $proj
''');
    final r = h.launchCubeSandbox(
      ['launch', 'strc', '--resume', 'u1'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
    expect(argvTail(r), ['--resume', 'u1']);
  });

  test('AC5: exit codes propagate unchanged with a tail present', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    Map<String, String> env() => {'HOME': home.path};
    expect(
      h
          .launchCubeSandbox(
            ['launch', 'argvp', '__exit', '0', '--tail'],
            cwd: proj,
            env: env(),
          )
          .exit,
      0,
    );
    expect(
      h
          .launchCubeSandbox(
            ['launch', 'argvp', '__exit', '7', '--tail'],
            cwd: proj,
            env: env(),
          )
          .exit,
      7,
    );
    expect(
      h
          .launchCubeSandbox(
            ['launch', 'argvp', '__int', '--tail'],
            cwd: proj,
            env: env(),
          )
          .exit,
      130,
      reason: 'SIGINT => 128+2 (I2)',
    );
  });

  test('AC3/I1: SBPL byte-identical with and without a tail', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final sbpl = h.launchCubeSandbox(
      ['sbpl', 'argvp'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(sbpl.exit, 0, reason: 'stderr: ${sbpl.stderr}');

    final noTail = h.launchCubeSandbox(
      ['launch', 'argvp'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(noTail.exit, 0, reason: 'stderr: ${noTail.stderr}');
    final withTail = h.launchCubeSandbox(
      ['launch', 'argvp', '--resume', 'u1'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(withTail.exit, 0, reason: 'stderr: ${withTail.stderr}');

    final cache = Directory('$proj/.cube-sandbox/cache');
    final staged = cache
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.sb'))
        .toList();
    expect(staged, hasLength(1), reason: 'same manifest => same key10');
    expect(
      staged.single.readAsStringSync(),
      sbpl.stdout,
      reason: 'staged profile from a launch WITH a tail == sbpl bytes',
    );
  });

  test('options before the profile still parse (reordered grammar)', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final r = h.launchCubeSandbox(
      ['launch', '--use-github', 'argvp', '--flag', 'v'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
    expect(argvTail(r), ['--flag', 'v']);
    final plain = h.launchCubeSandbox(
      ['sbpl', 'argvp'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    final gh = h.launchCubeSandbox(
      ['sbpl', '--use-github', 'argvp'],
      cwd: proj,
      env: {'HOME': home.path},
    );
    expect(gh.stdout, isNot(plain.stdout), reason: 'grant folded into key10');
  });

  test('AC4: strict verbs unchanged on trailing junk', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    Map<String, String> env() => {'HOME': home.path};

    final sbpl = h.launchCubeSandbox(
      ['sbpl', 'argvp', '--resume', 'u'],
      cwd: proj,
      env: env(),
    );
    expect(sbpl.exit, 2);
    expect(sbpl.stderr, contains('unknown option "--resume"'));

    final show = h.launchCubeSandbox(
      ['show', 'argvp', '--resume', 'u'],
      cwd: proj,
      env: env(),
    );
    expect(show.exit, 2);
    expect(show.stderr, contains('unknown option "--resume"'));

    final probe = h.launchCubeSandbox(
      ['probe', 'argvp', '--nope'],
      cwd: proj,
      env: env(),
    );
    expect(probe.exit, 2);
    expect(probe.stderr, contains('unknown option "--nope"'));

    final neu = h.launchCubeSandbox(
      ['new', 'a', 'b', '--command', 'x', '--agent-root', 'y'],
      cwd: proj,
      env: env(),
    );
    expect(neu.exit, 2);
    expect(neu.stderr, contains('exactly one name required'));

    final list = h.launchCubeSandbox(['list', 'junk'], cwd: proj, env: env());
    expect(list.exit, 0, reason: 'list ignores argv today; unchanged');
  });

  test('AC7: --yaml - stdin manifest composes with a tail', () {
    final home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => home.deleteSync(recursive: true));
    final manifest = File('$proj/.cube-sandbox/argvp.yaml').readAsStringSync();
    final exe = h.ensureBinary();
    // The binary reads the manifest from ITS stdin: pipe through a shell.
    final r = Process.runSync(
      '/bin/sh',
      [
        '-c',
        'printf \'%s\' "\$CUBE_MANIFEST" | "\$CUBE_EXE" launch --yaml - argvp --resume u1',
      ],
      workingDirectory: proj,
      environment: {
        'HOME': home.path,
        'CUBE_MANIFEST': manifest,
        'CUBE_EXE': exe,
      },
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    final lines = (r.stdout as String).split('\n')..removeLast();
    expect(lines, ['--resume', 'u1']);
  });
}
