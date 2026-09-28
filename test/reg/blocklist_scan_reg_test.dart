import 'package:cube_sandbox/src/folder_groups.dart';
import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:test/test.dart';

/// REG / AC11 — no profile for ANY flag combination contains an allow
/// touching ~/.ssh, ~/.gnupg or keychain paths (byte-scan of every
/// emitted profile).
void main() {
  const home = '/Users/dev';

  // every flag subset of the catalog, plus the empty set
  final flagSets = <Set<String>>[
    for (var mask = 0; mask < 1 << serviceCatalogIds.length; mask++)
      {
        for (var i = 0; i < serviceCatalogIds.length; i++)
          if (mask & (1 << i) != 0) serviceCatalogIds[i],
      },
  ];

  // allow lines that would GRANT an ungrantable root — either spelling,
  // read, metadata or write. None may exist in any emitted profile.
  final forbidden = <String>[];
  for (final suffix in kUngrantableHomeSuffixes) {
    for (final spelling in bothSpellingsOf('$home/$suffix')) {
      forbidden.add('(allow file-read* (subpath "$spelling")');
      forbidden.add('(allow file-write* (subpath "$spelling")');
      forbidden.add('(allow file-read-metadata (subpath "$spelling")');
    }
  }

  test('forbidden patterns are real patterns (sanity)', () {
    expect(forbidden, isNotEmpty);
    expect(flagSets.length, 8); // 2^3 subsets of {github, gitlab, nvm}
  });

  test('every flag combination x every preset scans clean', () {
    for (final flags in flagSets) {
      for (final id in HarnessPresets.ids) {
        final rt = resolveRuntime(
          HarnessPresets.load(id),
          services: flags,
          cwd: '/Users/dev/proj',
          home: home,
          env: {'HOME': home, 'TMPDIR': '/private/var/folders/ab/T123'},
          fs: _NoIO(),
        );
        final text = emitProfile(rt).text;
        for (final f in forbidden) {
          expect(
            text,
            isNot(contains(f)),
            reason: 'flags={$flags} preset=$id leaked grant $f',
          );
        }
      }
    }
  });

  test(
    'even a malicious EXTRA_WRITE knob cannot smuggle a write grant (E10)',
    () {
      expect(
        () => resolveRuntime(
          HarnessPresets.load('pi'),
          services: const {},
          cwd: '/Users/dev/proj',
          home: home,
          env: {'HOME': home, 'CUBE_SANDBOX_EXTRA_WRITE': '$home/.gnupg'},
          fs: _NoIO(),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );

  // --- Issue #101: folder groups obey the same per-direction contract.

  test('a selected group write: hitting a blocklisted root throws (E8)', () {
    for (final p in [
      '$home/.gnupg',
      '$home/.ssh',
      '$home/Library/Keychains',
      '/private$home/.gnupg',
    ]) {
      final doc = parseFolderGroups(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    write: [$p]\n',
        path: '$home/.cube-sandbox/folders.yaml',
        home: home,
      );
      expect(
        () => resolveFolderGroups(doc, ['g'], home: home),
        throwsA(isA<Exception>()),
        reason: 'write: [$p] must be rejected',
      );
    }
  });

  test(
    'a selected group read: hitting a blocklisted root warns + honors (E9)',
    () {
      final doc = parseFolderGroups(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    read: [~/.gnupg]\n',
        path: '$home/.cube-sandbox/folders.yaml',
        home: home,
      );
      final s = resolveFolderGroups(doc, ['g'], home: home);
      expect(s.read, ['$home/.gnupg']);
      expect(s.warnings, hasLength(1));
      expect(s.warnings.single, contains('NEVER silent'));
    },
  );

  test('no emitted profile with folder grants touches a blocklisted root', () {
    final doc = parseFolderGroups(
      'apiVersion: cube-sandbox/v1\ngroups:\n'
      '  wide:\n'
      '    write: [$home/work/wide, /Volumes/data/wide]\n'
      '    read: [$home/Library/Caches/big]\n',
      path: '$home/.cube-sandbox/folders.yaml',
      home: home,
    );
    final s = resolveFolderGroups(doc, ['wide'], home: home);
    final text = emitProfile(
      resolveRuntime(
        HarnessPresets.load('pi'),
        services: const {},
        cwd: '/Users/dev/proj',
        home: home,
        env: {'TMPDIR': '/private/var/folders/t/T1'},
        fs: _NoIO(),
        folderRead: s.read,
        folderWrite: s.write,
      ),
    ).text;
    for (final suffix in kUngrantableHomeSuffixes) {
      for (final spelling in bothSpellingsOf('$home/$suffix')) {
        expect(
          text.contains('(allow file-write* (subpath "$spelling")'),
          isFalse,
          reason: 'leaked grant $spelling',
        );
        expect(
          text.contains('(allow file-read* (subpath "$spelling")'),
          isFalse,
          reason: 'leaked read grant $spelling',
        );
      }
    }
  });
}

final class _NoIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
