import 'dart:io';

import 'package:cuberun/src/exceptions.dart';
import 'package:cuberun/src/resolver.dart';
import 'package:test/test.dart';

/// AC3 — resolution precedence: --file > project .cuberun/ > user
/// ~/.cuberun/ > preset; not-found lists where it looked + preset ids.
/// E8 — resolution keys on the FILENAME stem (metadata.name may differ).
void main() {
  late Directory tmp;
  late String proj;
  late String home;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cuberun-resolver-');
    proj = '${tmp.path}/proj';
    home = '${tmp.path}/home';
    await Directory(proj).create(recursive: true);
    await Directory(home).create(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  const body = '''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: whatever
spec:
  command: mycmd
  agentRoot: /tmp/state
''';

  HarnessResolver mk() => HarnessResolver(cwd: proj, home: home);

  test('preset resolves when nothing else exists', () {
    final r = mk().resolve('pi');
    expect(r.source, HarnessSource.preset);
    expect(r.spec.command, ['pi']);
    expect(r.path, isNull);
  });

  test('user ~/.cuberun shadows preset', () {
    Directory('$home/.cuberun').createSync(recursive: true);
    File('$home/.cuberun/pi.yaml').writeAsStringSync(body);
    final r = mk().resolve('pi');
    expect(r.source, HarnessSource.user);
    expect(r.spec.command, ['mycmd']);
  });

  test('project .cuberun shadows user + preset', () {
    Directory('$home/.cuberun').createSync(recursive: true);
    File('$home/.cuberun/pi.yaml').writeAsStringSync(body);
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/pi.yaml').writeAsStringSync(body);
    final r = mk().resolve('pi');
    expect(r.source, HarnessSource.project);
  });

  test('--file beats everything', () {
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/pi.yaml').writeAsStringSync(body);
    final f = '${tmp.path}/override.yaml';
    File(f).writeAsStringSync(body);
    final r = mk().resolve('pi', file: f);
    expect(r.source, HarnessSource.file);
    expect(r.path, f);
  });

  test('--file missing fails closed naming the file', () {
    expect(
      () => mk().resolve('pi', file: '${tmp.path}/nope.yaml'),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('not found'),
        ),
      ),
    );
  });

  test('not-found error lists every location + presets (loud)', () {
    try {
      mk().resolve('ghost');
      fail('unreachable');
    } on ConfigException catch (e) {
      expect(e.message, contains('ghost'));
      expect(e.message, contains('$proj/.cuberun/ghost.yaml'));
      expect(e.message, contains('$home/.cuberun/ghost.yaml'));
      expect(e.message, contains('presets(fa, omp, pi)'));
    }
  });

  test('E8: spec name keys on the FILENAME stem, not metadata.name', () {
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/myspecial.yaml').writeAsStringSync(body);
    final r = mk().resolve('myspecial');
    expect(r.spec.name, 'myspecial'); // stem, not "whatever"
    expect(r.spec.command, ['mycmd']);
  });

  test('broken manifest in the chain fails with the file path named', () {
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/broken.yaml').writeAsStringSync('apiVersion: nope\n');
    expect(
      () => mk().resolve('broken'),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf([contains('.cuberun/broken.yaml'), contains('apiVersion')]),
        ),
      ),
    );
  });

  test('list shows presets + files with source labels', () {
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/local.yaml').writeAsStringSync(body);
    Directory('$home/.cuberun').createSync(recursive: true);
    File('$home/.cuberun/personal.yaml').writeAsStringSync(body);
    final rows = mk().list();
    final stems = [for (final r in rows) r.stem];
    expect(stems, containsAll(['fa', 'omp', 'pi', 'local', 'personal']));
    final local = rows.firstWhere((r) => r.stem == 'local');
    expect(local.source, HarnessSource.project);
    final personal = rows.firstWhere((r) => r.stem == 'personal');
    expect(personal.source, HarnessSource.user);
    final pi = rows.firstWhere((r) => r.stem == 'pi');
    expect(pi.source, HarnessSource.preset);
  });

  // --yaml: inline manifest text (AC3 top rung).

  const inline = '''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: pi
spec:
  command: inlined
  agentRoot: /tmp/state
''';

  test('--yaml inline text parses through the strict parser', () {
    final r = mk().resolve('pi', yaml: inline);
    expect(r.source, HarnessSource.yaml);
    expect(r.path, isNull);
    expect(r.spec.command, ['inlined']);
    expect(r.spec.name, 'pi'); // no filename stem: metadata.name keys
  });

  test('--yaml beats project/user/preset (top of the chain)', () {
    Directory('$home/.cuberun').createSync(recursive: true);
    File('$home/.cuberun/pi.yaml').writeAsStringSync(body);
    Directory('$proj/.cuberun').createSync(recursive: true);
    File('$proj/.cuberun/pi.yaml').writeAsStringSync(body);
    final r = mk().resolve('pi', yaml: inline);
    expect(r.source, HarnessSource.yaml);
    expect(r.spec.command, ['inlined']); // chain never consulted
  });

  test('--yaml + --file fails closed naming the conflict', () {
    final f = '${tmp.path}/override.yaml';
    File(f).writeAsStringSync(body);
    expect(
      () => mk().resolve('pi', file: f, yaml: inline),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          '--yaml and --file: give one, not both',
        ),
      ),
    );
  });

  test('--yaml schema error names <inline yaml>', () {
    expect(
      () => mk().resolve('pi', yaml: 'apiVersion: nope\n'),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf([startsWith('<inline yaml>'), contains('apiVersion')]),
        ),
      ),
    );
  });

  test('--yaml empty-ish text fails closed naming <inline yaml>', () {
    expect(
      () => mk().resolve('pi', yaml: ''),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          startsWith('<inline yaml>'),
        ),
      ),
    );
  });
}
