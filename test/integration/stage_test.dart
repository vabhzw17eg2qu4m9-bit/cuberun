import 'dart:io';

import 'package:cuberun/src/stage.dart';
import 'package:test/test.dart';

/// E7 — content-addressed staging: collisions impossible by key, identical
/// text never rewritten (mtime stable), atomic rename leaves no tmp files,
/// the cache dir self-gitignores.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cuberun-stage-');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('stages under harness-<key10>.sb and creates .gitignore', () {
    final path = stageProfile(
      cacheDir: tmp.path,
      text: '(version 1)\n',
      key10: 'abc1230123',
    );
    expect(path, '${tmp.path}/harness-abc1230123.sb');
    expect(File(path).readAsStringSync(), '(version 1)\n');
    final gi = File('${tmp.path}/.gitignore');
    expect(gi.existsSync(), isTrue);
    expect(gi.readAsStringSync(), '*\n!.gitignore\n');
  });

  test('identical content is NOT rewritten (mtime stable)', () async {
    final path = stageProfile(cacheDir: tmp.path, text: 'same\n', key10: 'k1');
    final before = File(path).lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final path2 = stageProfile(cacheDir: tmp.path, text: 'same\n', key10: 'k1');
    expect(path2, path);
    expect(File(path).lastModifiedSync(), before);
  });

  test('different content under same key IS rewritten', () async {
    final path = stageProfile(cacheDir: tmp.path, text: 'v1\n', key10: 'k2');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    stageProfile(cacheDir: tmp.path, text: 'v2\n', key10: 'k2');
    expect(File(path).readAsStringSync(), 'v2\n');
    expect(
      File(path).lastModifiedSync().isAfter(
        DateTime.now().subtract(const Duration(seconds: 2)),
      ),
      isTrue,
    );
  });

  test('no .tmp litter left behind', () {
    stageProfile(cacheDir: tmp.path, text: 'x\n', key10: 'k3', pid: 999);
    final litter = Directory(
      tmp.path,
    ).listSync().where((e) => e.path.contains('.tmp.'));
    expect(litter, isEmpty);
  });

  test('creates nested cache dirs on demand', () {
    final deep = '${tmp.path}/a/b/c';
    final path = stageProfile(cacheDir: deep, text: 'x\n', key10: 'k4');
    expect(File(path).existsSync(), isTrue);
  });

  test('projectCacheDir shape', () {
    expect(projectCacheDir('/w/proj'), '/w/proj/.cuberun/cache');
  });
}
