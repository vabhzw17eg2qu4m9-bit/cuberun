import 'package:cube_sandbox/src/launch_argv.dart';
import 'package:test/test.dart';

/// UT-1 (issue #43): the pure launch-argv split — cube-sandbox options
/// precede the profile; every token after the first positional is the
/// harness argv tail, forwarded verbatim with order preserved (AC2).
void main() {
  group('splitLaunchArgv', () {
    test('no tail: options + profile only (E1)', () {
      final s = splitLaunchArgv(['--file', 'f.yaml', 'pi']);
      expect(s.args, ['--file', 'f.yaml', 'pi']);
      expect(s.tail, isEmpty);
    });

    test('flags after the profile are the harness tail (AC1/AC2)', () {
      final s = splitLaunchArgv(['omp', '--resume', 'u1']);
      expect(s.args, ['omp']);
      expect(s.tail, ['--resume', 'u1']);
    });

    test('exact cube-sandbox spellings stay tail after the profile (AC2)', () {
      final s = splitLaunchArgv([
        'pi',
        '--file',
        'x',
        '--yaml',
        'y',
        '--use-github',
      ]);
      expect(s.args, ['pi']);
      expect(s.tail, ['--file', 'x', '--yaml', 'y', '--use-github']);
    });

    test('options before the profile remain options, order preserved', () {
      final s = splitLaunchArgv([
        '--use-github',
        '--file',
        'f',
        'fa',
        '--resume',
        'u',
        '--flag',
        'v',
      ]);
      expect(s.args, ['--use-github', '--file', 'f', 'fa']);
      expect(s.tail, ['--resume', 'u', '--flag', 'v']);
    });

    test('E3: second positional is tail, not a profile error', () {
      final s = splitLaunchArgv(['pi', 'omp']);
      expect(s.args, ['pi']);
      expect(s.tail, ['omp']);
    });

    test('E4: empty-string tail token forwarded as-is', () {
      final s = splitLaunchArgv(['pi', '']);
      expect(s.tail, ['']);
    });

    test('AC7: --yaml - (stdin) composes with a tail', () {
      final s = splitLaunchArgv(['--yaml', '-', 'pi', '--resume', 'u']);
      expect(s.args, ['--yaml', '-', 'pi']);
      expect(s.tail, ['--resume', 'u']);
    });

    test('bare -- before any profile: command override owns the rest', () {
      final s = splitLaunchArgv(['--', 'echo', 'hi']);
      expect(s.args, ['--', 'echo', 'hi']);
      expect(s.tail, isEmpty);
    });

    test('bare -- after the profile keeps the command override intact', () {
      final s = splitLaunchArgv(['pi', '--', 'echo', 'hi']);
      expect(s.args, ['pi', '--', 'echo', 'hi']);
      expect(s.tail, isEmpty);
    });

    test('tail before -- stays tail; -- region stays the override', () {
      final s = splitLaunchArgv([
        '--use-github',
        'pi',
        '--resume',
        'u',
        '--',
        'echo',
        'hi',
      ]);
      expect(s.args, ['--use-github', 'pi', '--', 'echo', 'hi']);
      expect(s.tail, ['--resume', 'u']);
    });

    test('E2: options without a profile yield no tail (scan errors later)', () {
      final s = splitLaunchArgv(['--file', 'f']);
      expect(s.args, ['--file', 'f']);
      expect(s.tail, isEmpty);
    });

    test('empty argv', () {
      final s = splitLaunchArgv(<String>[]);
      expect(s.args, isEmpty);
      expect(s.tail, isEmpty);
    });
  });
}
