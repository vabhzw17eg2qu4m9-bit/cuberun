import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// REG — the SBPL text of all three presets is asserted against pinned
/// expectations (deny roots, metadata re-allows, grant lines, key10):
/// a diff in preset confinement is a RED build even when all behavior
/// tests stay green.
void main() {
  // FIXED machine facts => deterministic profiles => pinnable keys.
  HarnessRuntime fixed(String agentRoot, {List<String> extraRead = const []}) =>
      HarnessRuntime(
        projDir: '/Users/dev/proj',
        agentRoot: agentRoot,
        tmp: '/private/var/folders/ab/T123',
        extraRead: extraRead,
        extraWrite: const [],
        runtimeDirs: const [],
      );

  final fa = emitProfile(fixed('/Users/dev/.fah'));
  final omp = emitProfile(fixed('/Users/dev/.omp'));
  final pi = emitProfile(fixed('/Users/dev/.pi'));

  test('all three presets parse and emit', () {
    expect(HarnessPresets.ids, ['fa', 'omp', 'pi']);
    expect(fa.text.isNotEmpty, isTrue);
    expect(omp.text.isNotEmpty, isTrue);
    expect(pi.text.isNotEmpty, isTrue);
  });

  test('key10 pins (confinement drift detector)', () {
    // These literals ARE the regression pins: any change to profile
    // semantics for the same facts turns this red.
    expect(fa.key10, 'e8ee06804e');
    expect(omp.key10, 'a969c70e85');
    expect(pi.key10, 'c3f35f98a1');
  });

  test('identical facts => identical text, always', () {
    expect(emitProfile(fixed('/Users/dev/.fah')).text, fa.text);
    expect(emitProfile(fixed('/Users/dev/.omp')).text, omp.text);
    expect(emitProfile(fixed('/Users/dev/.pi')).text, pi.text);
  });

  for (final entry in {'fa': fa, 'omp': omp, 'pi': pi}.entries) {
    group('REG structural pins: ${entry.key}', () {
      final text = entry.value.text;

      test('header pinned (version/default/open network)', () {
        expect(text.split('\n').take(3), [
          '(version 1)',
          '(allow default)',
          '(allow network*)',
        ]);
        expect(text, isNot(contains('(deny network')));
      });

      test('deny roots pinned, both spellings, metadata re-allows', () {
        for (final root in kReadDenyRoots) {
          expect(text, contains('(deny file-read* (subpath "$root"))'));
          expect(
            text,
            contains('(allow file-read-metadata (subpath "$root"))'),
          );
        }
        expect(text, contains('(deny file-read* (subpath "/Users"))'));
        expect(text, contains('(deny file-read* (subpath "/private/Users"))'));
        expect(text, contains('(deny file-read* (subpath "/var"))'));
        expect(text, contains('(deny file-read* (subpath "/private/var"))'));
      });

      test('NO blanket read deny (E1: unbuildable — compiler aborts)', () {
        expect(text, isNot(contains('(deny file-read*)')));
      });

      test('system re-allows under /private/var pinned', () {
        expect(
          text,
          contains('(allow file-read* (subpath "/private/var/db/dyld"))'),
        );
        expect(
          text,
          contains('(allow file-read* (subpath "/private/var/run"))'),
        );
      });

      test('writes: bare deny + /dev/null + /dev/fd + rw roots only', () {
        expect(text, contains('(deny file-write*)'));
        expect(text, contains('(allow file-write* (literal "/dev/null"))'));
        expect(text, contains('(allow file-write* (subpath "/dev/fd"))'));
        expect(
          text,
          contains('(allow file-write* (subpath "/Users/dev/proj"))'),
        );
        expect(
          text,
          contains(
            '(allow file-write* (subpath "/private/var/folders/ab/T123"))',
          ),
        );
        final foreignWriteAllows = text
            .split('\n')
            .where((l) => l.startsWith('(allow file-write*'))
            .where(
              (l) =>
                  !l.contains('/dev/') &&
                  !l.contains('/Users/dev/proj') &&
                  !l.contains('/private/var/folders/ab/T123'),
            );
        expect(
          foreignWriteAllows,
          isEmpty,
          reason: 'no write allows outside the rw roots',
        );
      });

      test('no secret-ish tokens in text', () {
        expect(text, isNot(contains('ghp_')));
        expect(text, isNot(contains('sk-ant-')));
        expect(text, isNot(contains('BEGIN OPENSSH PRIVATE KEY')));
      });
    });
  }
}
