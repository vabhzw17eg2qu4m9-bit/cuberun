import 'dart:io';

import 'package:cube_sandbox/src/cache_policy.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// Issue #69 — cache provenance + shadow loudness: the staged `.sb` is
/// tied to the SOURCE document it was built from (`.src` stamp beside it,
/// mismatch ⇒ rebuild + loud warning), and a differing same-stem copy in
/// another chain location is named in a shadow warning. Byte-stability:
/// identical source ⇒ identical stamp ⇒ no churn.
void main() {
  late Directory tmp;
  late String proj;
  late String home;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cube-sandbox-cachepol-');
    proj = '${tmp.path}/proj';
    home = '${tmp.path}/home';
    await Directory('$proj/.cube-sandbox').create(recursive: true);
    await Directory('$home/.cube-sandbox').create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  const textA = 'apiVersion: cube-sandbox/v1\n# A\n';
  const textB = 'apiVersion: cube-sandbox/v1\n# B\n';

  ResolvedHarness rh({
    String? path,
    String? text,
    HarnessSource source = HarnessSource.project,
  }) => ResolvedHarness(
    spec: HarnessSpec(name: 'codemie', command: ['c'], agentRoot: '~/.a'),
    source: source,
    path: path,
    sourceText: text,
  );

  group('sourceStamp', () {
    test('is deterministic for identical provenance', () {
      expect(
        sourceStamp(rh(path: '$proj/codemie.yaml', text: textA)),
        sourceStamp(rh(path: '$proj/codemie.yaml', text: textA)),
      );
    });

    test('changes when the source path, text or label changes', () {
      final base = sourceStamp(rh(path: '$proj/codemie.yaml', text: textA));
      expect(
        sourceStamp(rh(path: '$home/codemie.yaml', text: textA)).fp,
        isNot(base.fp),
      );
      expect(
        sourceStamp(rh(path: '$proj/codemie.yaml', text: textB)).fp,
        isNot(base.fp),
      );
      expect(
        sourceStamp(
          rh(
            path: '$proj/codemie.yaml',
            text: textA,
            source: HarnessSource.user,
          ),
        ).fp,
        isNot(base.fp),
      );
    });
  });

  group('stageWithProvenance', () {
    test('first stage writes .sb + sidecar, no mismatch', () {
      final r = rh(path: '$proj/codemie.yaml', text: textA);
      final stamp = sourceStamp(r);
      final prev = stageWithProvenance(
        cacheDir: tmp.path,
        profile: const SbplProfile(
          text: '(version 1)\n(allow default)\n',
          key10: 'k69a',
        ),
        resolved: r,
      );
      expect(prev, isNull);
      expect(
        File('${tmp.path}/harness-k69a.sb').readAsStringSync(),
        const SbplProfile(
          text: '(version 1)\n(allow default)\n',
          key10: 'k69a',
        ).text,
      );
      expect(
        File(sidecarPath(tmp.path, 'k69a')).readAsStringSync(),
        '${stamp.fp}  ${stamp.detail}\n',
      );
    });

    test(
      'identical re-stage: quiet, sidecar not rewritten (mtime stable)',
      () async {
        final r = rh(path: '$proj/codemie.yaml', text: textA);
        stageWithProvenance(
          cacheDir: tmp.path,
          profile: const SbplProfile(
            text: '(version 1)\n(allow default)\n',
            key10: 'k69b',
          ),
          resolved: r,
        );
        final sidecar = File(sidecarPath(tmp.path, 'k69b'));
        final before = sidecar.lastModifiedSync();
        await Future<void>.delayed(const Duration(milliseconds: 1200));
        expect(
          stageWithProvenance(
            cacheDir: tmp.path,
            profile: const SbplProfile(
              text: '(version 1)\n(allow default)\n',
              key10: 'k69b',
            ),
            resolved: r,
          ),
          isNull,
        );
        expect(sidecar.lastModifiedSync(), before);
      },
    );

    test('same key from a changed source: previous provenance returned', () {
      // Emit-identical edit (e.g. metadata.description only): key10 stays,
      // the sidecar must flag the source change and then carry the new
      // stamp (loud once, quiet after).
      final prev = stageWithProvenance(
        cacheDir: tmp.path,
        profile: const SbplProfile(
          text: '(version 1)\n(allow default)\n',
          key10: 'k69c',
        ),
        resolved: rh(path: '$proj/codemie.yaml', text: textA),
      );
      expect(prev, isNull);
      final mismatch = stageWithProvenance(
        cacheDir: tmp.path,
        profile: const SbplProfile(
          text: '(version 1)\n(allow default)\n',
          key10: 'k69c',
        ),
        resolved: rh(path: '$proj/codemie.yaml', text: textB),
      );
      expect(mismatch!.detail, contains('$proj/codemie.yaml'));
      final now = readSourceStamp(tmp.path, 'k69c');
      expect(now, isNotNull);
      expect(
        now!.fp,
        sourceStamp(rh(path: '$proj/codemie.yaml', text: textB)).fp,
      );
      // Loud exactly once: the refreshed provenance matches now.
      expect(
        stageWithProvenance(
          cacheDir: tmp.path,
          profile: const SbplProfile(
            text: '(version 1)\n(allow default)\n',
            key10: 'k69c',
          ),
          resolved: rh(path: '$proj/codemie.yaml', text: textB),
        ),
        isNull,
      );
    });

    test('legacy cache without sidecar is adopted silently', () {
      File('${tmp.path}/harness-k69d.sb').writeAsStringSync('(version 1)\n');
      expect(
        stageWithProvenance(
          cacheDir: tmp.path,
          profile: const SbplProfile(
            text: '(version 1)\n(allow default)\n',
            key10: 'k69d',
          ),
          resolved: rh(path: '$proj/codemie.yaml', text: textA),
        ),
        isNull,
      );
      expect(File(sidecarPath(tmp.path, 'k69d')).existsSync(), isTrue);
    });
  });

  group('readSourceStamp', () {
    test('absent sidecar reads as null', () {
      expect(readSourceStamp(tmp.path, 'nope'), isNull);
    });

    test('unreadable sidecar (chmod 000) reads as null, never throws', () {
      final sidecar = File(sidecarPath(tmp.path, 'kperm'));
      sidecar.writeAsStringSync('deadbeef  x\n');
      Process.runSync('chmod', ['000', sidecar.path]);
      addTearDown(() => Process.runSync('chmod', ['644', sidecar.path]));
      expect(readSourceStamp(tmp.path, 'kperm'), isNull);
    });

    test('non-UTF-8 corrupt sidecar reads as null, never throws (AC6)', () {
      File(
        sidecarPath(tmp.path, 'kbad'),
      ).writeAsBytesSync([0xff, 0xfe, 0x00, 0x81, 0x9c]);
      expect(readSourceStamp(tmp.path, 'kbad'), isNull);
    });
  });

  group('shadowedCopies (E1 loudness)', () {
    test('no other copy — no shadow', () {
      expect(
        shadowedCopies(
          stem: 'codemie',
          winnerPath: '$proj/.cube-sandbox/codemie.yaml',
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        isEmpty,
      );
    });

    test('identical copy is not a shadow', () {
      File('$home/.cube-sandbox/codemie.yaml').writeAsStringSync(textA);
      expect(
        shadowedCopies(
          stem: 'codemie',
          winnerPath: '$proj/.cube-sandbox/codemie.yaml',
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        isEmpty,
      );
    });

    test('differing lower-precedence copy is named (the reporter trap)', () {
      // The operator edits one copy; the chain still picks the other.
      File('$home/.cube-sandbox/codemie.yaml').writeAsStringSync(textB);
      expect(
        shadowedCopies(
          stem: 'codemie',
          winnerPath: '$proj/.cube-sandbox/codemie.yaml',
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        ['$home/.cube-sandbox/codemie.yaml'],
      );
    });

    test('differing higher-precedence loser is named when user wins', () {
      File('$proj/.cube-sandbox/codemie.yaml').writeAsStringSync(textB);
      expect(
        shadowedCopies(
          stem: 'codemie',
          winnerPath: '$home/.cube-sandbox/codemie.yaml',
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        ['$proj/.cube-sandbox/codemie.yaml'],
      );
    });

    test('preset/inline winner: any differing same-stem file is a shadow', () {
      File('$proj/.cube-sandbox/pi.yaml').writeAsStringSync(textB);
      expect(
        shadowedCopies(
          stem: 'pi',
          winnerPath: null,
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        ['$proj/.cube-sandbox/pi.yaml'],
      );
      File('$proj/.cube-sandbox/pi.yaml').writeAsStringSync(textA);
      expect(
        shadowedCopies(
          stem: 'pi',
          winnerPath: null,
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        isEmpty,
      );
    });

    test('--file winner is not shadowed by itself', () {
      final winner = '$proj/.cube-sandbox/codemie.yaml';
      expect(
        shadowedCopies(
          stem: 'codemie',
          winnerPath: winner,
          winnerText: textA,
          projectDir: '$proj/.cube-sandbox',
          userDir: '$home/.cube-sandbox',
        ),
        isEmpty,
      );
    });
  });
}
