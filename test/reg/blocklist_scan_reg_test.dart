import 'package:cuberun/src/presets.dart';
import 'package:cuberun/src/runtime.dart';
import 'package:cuberun/src/sbpl.dart';
import 'package:cuberun/src/service_grants.dart';
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
          env: {'HOME': home, 'CUBERUN_EXTRA_WRITE': '$home/.gnupg'},
          fs: _NoIO(),
        ),
        throwsA(isA<Exception>()),
      );
    },
  );
}

final class _NoIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
