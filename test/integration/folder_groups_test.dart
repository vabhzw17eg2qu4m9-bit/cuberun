import 'dart:io';

import 'package:cube_sandbox/src/cache_policy.dart';
import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/folder_groups.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// IT for folder groups (issue #101): the real groups file on disk plus
/// the stage/provenance cache contract under selections (AC8, E10, E14).
void main() {
  late Directory tmp;
  late String home;
  late String cacheDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cube-sandbox-folders-it-');
    home = '${tmp.path}/home';
    Directory('$home/.cube-sandbox').createSync(recursive: true);
    cacheDir = '${tmp.path}/proj/.cube-sandbox/cache';
  });

  tearDown(() async => tmp.delete(recursive: true));

  File groupsFile() => File('$home/.cube-sandbox/folders.yaml');

  ResolvedHarness resolvedFor() => const ResolvedHarness(
    spec: HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
    source: HarnessSource.yaml,
    sourceText: 'manifest text',
  );

  HarnessRuntime rtFor(Iterable<String> write) => resolveRuntime(
    const HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
    services: const {},
    cwd: '${tmp.path}/proj',
    home: home,
    env: const {'TMPDIR': '/private/var/folders/t/T1'},
    folderWrite: write.toList(),
  );

  SelectedFolderGroups sel(String name) =>
      resolveFolderGroups(loadFolderGroups(home: home)!, [name], home: home);

  test(
    'loadFolderGroups: missing file -> null; present -> parsed with ~ expanded',
    () {
      expect(
        loadFolderGroups(home: home),
        isNull,
        reason: 'E14: absent file is a no-op',
      );
      groupsFile().writeAsStringSync(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    write: [~/w]\n',
      );
      final doc = loadFolderGroups(home: home)!;
      expect(doc.groups['g']!.write, ['$home/w']);
    },
  );

  test(
    'loadFolderGroups: malformed file -> ConfigException naming the file',
    () {
      groupsFile().writeAsStringSync('apiVersion: [oops\n');
      expect(
        () => loadFolderGroups(home: home),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('$home/.cube-sandbox/folders.yaml'),
          ),
        ),
      );
    },
  );

  test('AC8: same selection => same key10 + mtime-stable .sb; '
      'changed selection => new key + fresh stage + .src names the group', () {
    groupsFile().writeAsStringSync(
      'apiVersion: cube-sandbox/v1\ngroups:\n'
      '  ga:\n    write: [~/wa]\n'
      '  gb:\n    write: [~/wb]\n',
    );

    final a1 = emitProfile(rtFor(sel('ga').write));
    final stampA = folderGroupsStamp(sel('ga').groups);
    expect(
      stageWithProvenance(
        cacheDir: cacheDir,
        profile: a1,
        resolved: resolvedFor(),
        folderStamp: stampA,
      ),
      isNull,
      reason: 'first stage: no previous stamp',
    );
    final sbA = File('$cacheDir/harness-${a1.key10}.sb');
    expect(sbA.existsSync(), isTrue);

    // Same selection again: identical key, never rewritten (mtime-stable).
    final m1 = sbA.statSync().modified;
    expect(
      stageWithProvenance(
        cacheDir: cacheDir,
        profile: a1,
        resolved: resolvedFor(),
        folderStamp: stampA,
      ),
      isNull,
    );
    expect(sbA.statSync().modified, m1, reason: 'E7: mtime stability');

    // Different selection: new key10, fresh stage, .src names group + entry.
    final b = emitProfile(rtFor(sel('gb').write));
    expect(b.key10, isNot(a1.key10), reason: 'selection change => new key10');
    stageWithProvenance(
      cacheDir: cacheDir,
      profile: b,
      resolved: resolvedFor(),
      folderStamp: folderGroupsStamp(sel('gb').groups),
    );
    final srcB = File('$cacheDir/harness-${b.key10}.src').readAsStringSync();
    expect(srcB, contains('gb'));
    expect(srcB, contains('$home/wb'));
  });

  test('AC8: renamed group with identical entries => same key10 but a LOUD '
      'provenance refresh (stamp inputs moved)', () {
    groupsFile().writeAsStringSync(
      'apiVersion: cube-sandbox/v1\ngroups:\n  ga:\n    write: [~/wa]\n',
    );
    final a1 = emitProfile(rtFor(sel('ga').write));
    stageWithProvenance(
      cacheDir: cacheDir,
      profile: a1,
      resolved: resolvedFor(),
      folderStamp: folderGroupsStamp(sel('ga').groups),
    );

    groupsFile().writeAsStringSync(
      'apiVersion: cube-sandbox/v1\ngroups:\n  gz:\n    write: [~/wa]\n',
    );
    final a2 = emitProfile(rtFor(sel('gz').write));
    expect(a2.key10, a1.key10, reason: 'identical entries => identical emit');
    final previous = stageWithProvenance(
      cacheDir: cacheDir,
      profile: a2,
      resolved: resolvedFor(),
      folderStamp: folderGroupsStamp(sel('gz').groups),
    );
    expect(
      previous,
      isNotNull,
      reason: 'same key re-staged from a changed stamp',
    );
    expect(previous!.detail, contains('ga'));
  });
}
