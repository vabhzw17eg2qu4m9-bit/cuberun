import 'dart:io';

import 'package:cuberun/src/exceptions.dart';
import 'package:cuberun/src/harness_manifest.dart';
import 'package:cuberun/src/scaffold.dart';
import 'package:test/test.dart';

/// AC8 — scaffold round-trip: `cuberun new` output parses through the
/// strict parser and lands in `.cuberun/<name>.yaml`.
void main() {
  late Directory tmp;
  late String proj;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cuberun-scaffold-');
    proj = '${tmp.path}/proj';
    await Directory(proj).create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('scaffold lands in .cuberun/<name>.yaml and round-trips', () {
    final path = scaffoldProfile(
      name: 'myharness',
      command: 'myh',
      agentRoot: '~/.myh',
      projectDir: proj,
    );
    expect(path, '$proj/.cuberun/myharness.yaml');
    final text = File(path).readAsStringSync();
    final spec = HarnessSpec.fromYamlText(text, sourcePath: path);
    expect(spec.name, 'myharness');
    expect(spec.command, ['myh']);
    expect(spec.agentRoot, '~/.myh');
  });

  test('refuses to overwrite an existing profile', () {
    scaffoldProfile(
      name: 'dup',
      command: 'x',
      agentRoot: '~/.x',
      projectDir: proj,
    );
    expect(
      () => scaffoldProfile(
        name: 'dup',
        command: 'x',
        agentRoot: '~/.x',
        projectDir: proj,
      ),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('refusing to overwrite'),
        ),
      ),
    );
  });

  test('bad name rejected before touching disk', () {
    expect(
      () => scaffoldProfile(
        name: 'Bad_Name',
        command: 'x',
        agentRoot: '~/.x',
        projectDir: proj,
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(File('$proj/.cuberun/Bad_Name.yaml').existsSync(), isFalse);
  });

  test('bad agentRoot rejected (strict sanitation at scaffold time)', () {
    expect(
      () => scaffoldProfile(
        name: 'ok',
        command: 'x',
        agentRoot: 'relative',
        projectDir: proj,
      ),
      throwsA(isA<ConfigException>()),
    );
  });
}
