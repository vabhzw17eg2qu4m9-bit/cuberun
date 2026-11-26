import 'dart:io';

import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/service_grants.dart'
    show selectServiceProfiles;
import 'package:cube_sandbox/src/service_profiles.dart';
import 'package:test/test.dart';

/// Issue #204 — services.yaml: strict parse with file:line errors,
/// tilde expansion, scalar env values, lazy load (null when absent),
/// and selection of non-built-in profiles (the catalog always shadows).
void main() {
  const home = '/Users/dev';

  group('parse (strict, file:line errors)', () {
    test('valid document: description/read/write/env, tilde expanded', () {
      final doc = parseServiceProfiles(
        'apiVersion: cube-sandbox/v1\nservices:\n'
        '  demo:\n'
        '    description: scratch grants\n'
        '    read: [~/shared/notes]\n'
        '    write: [~/work/scratch]\n'
        '    env:\n'
        '      SCRATCH_HOST: localhost\n',
        path: '$home/.cube-sandbox/services.yaml',
        home: home,
      );
      final p = doc.services['demo']!;
      expect(p.name, 'demo');
      expect(p.description, 'scratch grants');
      expect(p.read, ['$home/shared/notes']);
      expect(p.write, ['$home/work/scratch']);
      expect(p.env, {'SCRATCH_HOST': 'localhost'});
    });

    test('empty services map is a valid no-op', () {
      final doc = parseServiceProfiles(
        'apiVersion: cube-sandbox/v1\nservices: {}\n',
        path: 'services.yaml',
        home: home,
      );
      expect(doc.services, isEmpty);
    });

    test('absent services key is a valid no-op', () {
      final doc = parseServiceProfiles(
        'apiVersion: cube-sandbox/v1\n',
        path: 'services.yaml',
        home: home,
      );
      expect(doc.services, isEmpty);
    });

    test('unknown top-level key names file AND line (AC13 shape)', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices: {}\nfoo: 1\n',
          path: '$home/.cube-sandbox/services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:3:'), contains('unknown key')]),
          ),
        ),
      );
    });

    test('wrong apiVersion names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v2\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:1:'), contains('cube-sandbox/v1')]),
          ),
        ),
      );
    });

    test('bad service name names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n  Demo: {}\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('services.yaml:3:'),
              contains('[a-z0-9][a-z0-9-]*'),
            ]),
          ),
        ),
      );
    });

    test('unknown service body key names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n'
          '  demo:\n    extra: 1\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:4:'), contains('unknown key')]),
          ),
        ),
      );
    });

    test('non-list direction names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n'
          '  demo:\n    read: not-a-list\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:4:'), contains('must be a list')]),
          ),
        ),
      );
    });

    test('unsafe path (dot-dot climb) rejected, file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n'
          '  demo:\n    write: [../escape]\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:4:'), contains('..')]),
          ),
        ),
      );
    });

    test('non-scalar env value names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n'
          '  demo:\n    env:\n      K: [a, b]\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:5:'), contains('scalar')]),
          ),
        ),
      );
    });

    test('bad env name names file AND line', () {
      expect(
        () => parseServiceProfiles(
          'apiVersion: cube-sandbox/v1\nservices:\n'
          '  demo:\n    env:\n      BAD-NAME: x\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:5:'), contains('env name')]),
          ),
        ),
      );
    });

    test('invalid yaml names file AND line', () {
      expect(
        () => parseServiceProfiles(
          // duplicate key: the yaml parser throws with a real span
          'apiVersion: cube-sandbox/v1\napiVersion: cube-sandbox/v1\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('services.yaml:2:'), contains('invalid yaml')]),
          ),
        ),
      );
    });

    test('empty document rejected', () {
      expect(
        () => parseServiceProfiles('', path: 'services.yaml', home: home),
        throwsA(isA<ConfigException>()),
      );
    });

    test('non-map document rejected', () {
      expect(
        () => parseServiceProfiles(
          '- a\n- b\n',
          path: 'services.yaml',
          home: home,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('load + select', () {
    test('load returns null when the file is absent (lazy, E14-style)', () {
      final tmp = Directory.systemTemp.createTempSync('cube-sandbox-svc-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      expect(loadServiceProfiles(home: tmp.path), isNull);
    });

    test('load parses an existing file', () {
      final tmp = Directory.systemTemp.createTempSync('cube-sandbox-svc-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      Directory('${tmp.path}/.cube-sandbox').createSync();
      File('${tmp.path}/.cube-sandbox/services.yaml').writeAsStringSync(
        'apiVersion: cube-sandbox/v1\nservices:\n'
        '  demo:\n    write: [~/scratch]\n',
      );
      final doc = loadServiceProfiles(home: tmp.path)!;
      expect(doc.services.keys, ['demo']);
      expect(doc.services['demo']!.write, ['${tmp.path}/scratch']);
    });

    test('select keeps non-built-ins only, sorted (E9), catalog shadows', () {
      final doc = parseServiceProfiles(
        'apiVersion: cube-sandbox/v1\nservices:\n'
        '  demo2: {}\n'
        '  alpha: {}\n'
        '  github: {}\n',
        path: 'services.yaml',
        home: home,
      );
      final selected = selectServiceProfiles(doc, {'github', 'demo2', 'alpha'});
      expect(selected.map((p) => p.name), [
        'alpha',
        'demo2',
      ], reason: 'github is catalog-owned; names sorted for E9');
    });

    test('select on a null doc is empty', () {
      expect(selectServiceProfiles(null, {'demo'}), isEmpty);
    });
  });
}
