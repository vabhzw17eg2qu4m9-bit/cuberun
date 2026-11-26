import 'dart:io';

import 'package:cube_sandbox/src/agents_md.dart';
import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:cube_sandbox/src/service_profiles.dart';
import 'package:test/test.dart';

/// Issue #204 — AGENTS.md ensure path: write-if-missing (AC1), second run
/// is a byte+mtime no-op (AC2), a user-owned file is preserved with
/// exactly one stderr notice (AC3), init --force is the only overwrite
/// seam (AC4), the resolver hook materializes it on user-dot-dir verbs,
/// and the unknown-service error points at the manual.
void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-agentsmd-');
    home = tmp.path;
    resetAgentsMdNotice();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('ensureAgentsMd', () {
    test('AC1: fresh home — dir + file created with the generated text', () {
      final notices = <String>[];
      final notice = ensureAgentsMd(home, err: notices.add);
      final f = File('$home/.cube-sandbox/AGENTS.md');
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), generateAgentsMd());
      expect(notice, isNull);
      expect(notices, isEmpty);
    });

    test('AC2: second run is a no-op (content + mtime unchanged)', () {
      ensureAgentsMd(home);
      final f = File('$home/.cube-sandbox/AGENTS.md');
      final before = f.lastModifiedSync();
      final notice = ensureAgentsMd(home);
      expect(notice, isNull);
      expect(f.lastModifiedSync(), before);
      expect(f.readAsStringSync(), generateAgentsMd());
    });

    test(
      'AC3: user-owned differing file preserved, ONE notice per process',
      () {
        final f = Directory('$home/.cube-sandbox')..createSync(recursive: true);
        File('${f.path}/AGENTS.md').writeAsStringSync('# mine, not yours\n');
        final notices = <String>[];
        ensureAgentsMd(home, err: notices.add);
        ensureAgentsMd(home, err: notices.add);
        expect(
          File('${f.path}/AGENTS.md').readAsStringSync(),
          '# mine, not yours\n',
          reason: 'never silently overwritten',
        );
        expect(notices, hasLength(1));
        expect(notices.single, contains('init --force'));
      },
    );

    test('identical existing file: no notice, no rewrite', () {
      Directory('$home/.cube-sandbox').createSync(recursive: true);
      final f = File('$home/.cube-sandbox/AGENTS.md')
        ..writeAsStringSync(generateAgentsMd());
      final before = f.lastModifiedSync();
      final notices = <String>[];
      expect(ensureAgentsMd(home, err: notices.add), isNull);
      expect(notices, isEmpty);
      expect(f.lastModifiedSync(), before);
    });

    test('never throws when the home cannot host the dot-dir', () {
      final blocker = File('${tmp.path}/blocker')..writeAsStringSync('x');
      final notices = <String>[];
      expect(
        () => ensureAgentsMd(blocker.path, err: notices.add),
        returnsNormally,
      );
      expect(notices, isEmpty);
    });
  });

  group('initAgentsMd (the overwrite seam)', () {
    test('missing file: written, path reported', () {
      final out = <String>[];
      final code = initAgentsMd(home: home, force: false, out: out.add);
      expect(code, 0);
      expect(
        File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
        generateAgentsMd(),
      );
      expect(out.single, contains('AGENTS.md'));
    });

    test('AC4: differing file + no --force: preserved + notice', () {
      Directory('$home/.cube-sandbox').createSync(recursive: true);
      File('$home/.cube-sandbox/AGENTS.md').writeAsStringSync('# mine\n');
      final out = <String>[];
      final err = <String>[];
      final code = initAgentsMd(
        home: home,
        force: false,
        out: out.add,
        err: err.add,
      );
      expect(code, 0);
      expect(
        File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
        '# mine\n',
      );
      expect(err.single, contains('init --force'));
    });

    test('AC4: differing file + --force: replaced with generated text', () {
      Directory('$home/.cube-sandbox').createSync(recursive: true);
      File('$home/.cube-sandbox/AGENTS.md').writeAsStringSync('# mine\n');
      final out = <String>[];
      final code = initAgentsMd(home: home, force: true, out: out.add);
      expect(code, 0);
      expect(
        File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
        generateAgentsMd(),
      );
    });

    test('identical file + --force: still a byte-identical refresh', () {
      Directory('$home/.cube-sandbox').createSync(recursive: true);
      File(
        '$home/.cube-sandbox/AGENTS.md',
      ).writeAsStringSync(generateAgentsMd());
      final out = <String>[];
      final code = initAgentsMd(home: home, force: true, out: out.add);
      expect(code, 0);
      expect(
        File('$home/.cube-sandbox/AGENTS.md').readAsStringSync(),
        generateAgentsMd(),
      );
    });
  });

  group('resolver hook', () {
    test('preset resolution materializes the manual in a fresh home', () {
      HarnessResolver(cwd: '${tmp.path}/proj', home: home).resolve('pi');
      expect(File('$home/.cube-sandbox/AGENTS.md').existsSync(), isTrue);
    });

    test('list() materializes the manual in a fresh home (AC1 verb)', () {
      HarnessResolver(cwd: '${tmp.path}/proj', home: home).list();
      expect(File('$home/.cube-sandbox/AGENTS.md').existsSync(), isTrue);
    });

    test('project-profile resolution leaves the user dir alone', () {
      final proj = Directory('${tmp.path}/proj/.cube-sandbox')
        ..createSync(recursive: true);
      File('${proj.path}/mine.yaml').writeAsStringSync(
        'apiVersion: cube-sandbox/v1\nkind: Harness\n'
        'metadata:\n  name: mine\nspec:\n  command: x\n  agentRoot: /tmp/x\n',
      );
      HarnessResolver(cwd: '${tmp.path}/proj', home: home).resolve('mine');
      expect(
        Directory('$home/.cube-sandbox').existsSync(),
        isFalse,
        reason: 'no user-dot-dir resolution, no write',
      );
    });
  });

  group('fail-closed unknown service points at the manual (AC12 core)', () {
    test('message lists catalog + config profiles + AGENTS.md', () {
      final doc = parseServiceProfiles(
        'apiVersion: cube-sandbox/v1\nservices:\n  demo: {}\n',
        path: 'services.yaml',
        home: home,
      );
      expect(
        () => resolveServiceGrants({'nope'}, home: home, profiles: doc),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([
              contains('--use-nope'),
              contains('catalog: github, gitlab, nvm, uv'),
              contains('demo'),
              contains('AGENTS.md'),
            ]),
          ),
        ),
      );
    });

    test('no services.yaml: the message says so', () {
      expect(
        () => resolveServiceGrants({'nope'}, home: home),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf([contains('catalog: github, gitlab, nvm, uv')]),
          ),
        ),
      );
    });
  });
}
