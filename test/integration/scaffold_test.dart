import 'dart:io';

import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/scaffold.dart';
import 'package:test/test.dart';

/// AC8 — scaffold round-trip: `cube-sandbox new` output parses through the
/// strict parser and lands in `.cube-sandbox/<name>.yaml`.
void main() {
  late Directory tmp;
  late String proj;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cube-sandbox-scaffold-');
    proj = '${tmp.path}/proj';
    await Directory(proj).create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('scaffold lands in .cube-sandbox/<name>.yaml and round-trips', () {
    final path = scaffoldProfile(
      name: 'myharness',
      command: 'myh',
      agentRoot: '~/.myh',
      projectDir: proj,
    );
    expect(path, '$proj/.cube-sandbox/myharness.yaml');
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
    expect(File('$proj/.cube-sandbox/Bad_Name.yaml').existsSync(), isFalse);
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
