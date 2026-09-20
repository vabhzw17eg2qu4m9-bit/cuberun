import 'package:cuberun/src/runtime.dart';
import 'package:cuberun/src/sbpl.dart';
import 'package:test/test.dart';

/// AC4 — determinism: identical runtime facts => byte-identical SBPL and
/// key10; ANY grant change => different key10; rules emitted in
/// comparator order (two sorted sections: writes then reads).
/// E1 — deny roots are CURATED (no blanket read deny), network open.
/// E2 — both spellings present, metadata re-allows under deny roots.
void main() {
  HarnessRuntime rt({
    String projDir = '/Users/dev/proj',
    String agentRoot = '/Users/dev/.pi',
    String tmp = '/private/var/folders/ab/T123',
    List<String> extraRead = const [],
    List<String> extraWrite = const [],
    List<String> runtimeDirs = const [],
  }) => HarnessRuntime(
    projDir: projDir,
    agentRoot: agentRoot,
    tmp: tmp,
    extraRead: extraRead,
    extraWrite: extraWrite,
    runtimeDirs: runtimeDirs,
  );

  test('byte-identical for identical facts', () {
    final a = emitProfile(rt());
    final b = emitProfile(rt());
    expect(a.text, b.text);
    expect(a.key10, b.key10);
    expect(a.key10, hasLength(10));
    expect(a.key10, matches(RegExp(r'^[0-9a-f]{10}$')));
  });

  test('ANY grant change changes key10', () {
    final base = emitProfile(rt()).key10;
    expect(
      emitProfile(rt(extraRead: ['/Users/dev/.config'])).key10,
      isNot(base),
    );
    expect(emitProfile(rt(extraWrite: ['/Users/dev/rw'])).key10, isNot(base));
    expect(emitProfile(rt(runtimeDirs: ['/opt/homebrew'])).key10, isNot(base));
    expect(emitProfile(rt(agentRoot: '/Users/dev/.other')).key10, isNot(base));
    expect(emitProfile(rt(projDir: '/Users/dev/other')).key10, isNot(base));
    expect(
      emitProfile(rt(tmp: '/private/var/folders/zz/T9')).key10,
      isNot(base),
    );
  });

  test('header: version, allow default, open network (E1)', () {
    final lines = emitProfile(rt()).text.split('\n');
    expect(lines.take(3), [
      '(version 1)',
      '(allow default)',
      '(allow network*)',
    ]);
    expect(emitProfile(rt()).text, isNot(contains('(deny network')));
  });

  test('writes deny-by-default with explicit allows only', () {
    final text = emitProfile(rt(extraWrite: ['/Users/dev/rw'])).text;
    final writeLines = text
        .split('\n')
        .where((l) => l.contains('file-write'))
        .toList();
    expect(writeLines.first, '(deny file-write*)');
    expect(
      writeLines,
      containsAll([
        '(allow file-write* (literal "/dev/null"))',
        '(allow file-write* (subpath "/dev/fd"))',
        '(allow file-write* (subpath "/Users/dev/proj"))',
        '(allow file-write* (subpath "/Users/dev/.pi"))',
        '(allow file-write* (subpath "/private/var/folders/ab/T123"))',
        '(allow file-write* (subpath "/Users/dev/rw"))',
      ]),
    );
    expect(
      writeLines
          .where((l) => l.startsWith('(allow') && l.contains('/Users'))
          .where(
            (l) =>
                !l.contains('/Users/dev/proj') &&
                !l.contains('/Users/dev/.pi') &&
                !l.contains('/Users/dev/rw'),
          ),
      isEmpty,
    );
  });

  test('curated deny roots, both spellings, metadata re-allows (E1+E2)', () {
    final text = emitProfile(rt()).text;
    for (final root in [
      '/Users',
      '/private/Users',
      '/private/var',
      '/var',
      '/Volumes',
      '/Network',
      '/home',
      '/net',
    ]) {
      expect(text, contains('(deny file-read* (subpath "$root"))'));
      expect(text, contains('(allow file-read-metadata (subpath "$root"))'));
    }
    // NO blanket read deny — unbuildable on this backend (E1).
    expect(text, isNot(contains('(deny file-read*)')));
    // system re-allows under /private/var
    expect(
      text,
      contains('(allow file-read* (subpath "/private/var/db/dyld"))'),
    );
    expect(text, contains('(allow file-read* (subpath "/private/var/run"))'));
  });

  test('read grants re-allowed with both spellings; rw grants read too', () {
    final text = emitProfile(
      rt(extraRead: ['/Users/dev/.config'], extraWrite: ['/Users/dev/rw']),
    ).text;
    expect(text, contains('(allow file-read* (subpath "/Users/dev/.config"))'));
    expect(text, contains('(allow file-read* (subpath "/Users/dev/rw"))'));
  });

  test('runtime dirs get read allows (E5)', () {
    final text = emitProfile(rt(runtimeDirs: ['/opt/homebrew'])).text;
    expect(text, contains('(allow file-read* (subpath "/opt/homebrew"))'));
  });

  test('tmp realpath grant in its /private spelling (E2)', () {
    final text = emitProfile(rt(tmp: '/private/var/folders/ab/T123')).text;
    expect(
      text,
      contains('(allow file-read* (subpath "/private/var/folders/ab/T123"))'),
    );
    expect(
      text,
      contains('(allow file-write* (subpath "/private/var/folders/ab/T123"))'),
    );
  });

  test('ordering: writes section first, sorted by comparator', () {
    final lines = emitProfile(
      rt(extraWrite: ['/Users/dev/a'], extraRead: ['/Users/dev/z']),
    ).text.split('\n').where((l) => l.isNotEmpty).toList();
    final firstRead = lines.indexWhere((l) => l.contains('file-read'));
    final lastWrite = lines.lastIndexWhere((l) => l.contains('file-write'));
    expect(lastWrite, lessThan(firstRead));

    final writes = lines.where((l) => l.contains('file-write')).toList();
    expect(writes.first, '(deny file-write*)'); // bare sorts first (-1)

    // length ordering within allows: /dev/fd before /dev/null before paths
    final fd = writes.indexWhere((l) => l.contains('"/dev/fd"'));
    final nullIdx = writes.indexWhere((l) => l.contains('"/dev/null"'));
    expect(fd, lessThan(nullIdx));
  });

  test('trailing newline, deterministic text', () {
    final text = emitProfile(rt()).text;
    expect(text.endsWith('\n'), isTrue);
    expect(text, emitProfile(rt()).text);
  });
}
