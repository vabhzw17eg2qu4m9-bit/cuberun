import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:test/test.dart';

/// E10 / AC11 (UT) — ungrantable paths: ~/.ssh, ~/.gnupg,
/// ~/Library/Keychains (both spellings) are rejected from every
/// DECLARATIVE source; CUBE_SANDBOX_EXTRA_READ is the escape hatch (honored,
/// warning collected — never silent); CUBE_SANDBOX_EXTRA_WRITE never.
void main() {
  const home = '/Users/dev';

  HarnessSpec specWith({
    List<String> extraRead = const [],
    List<String> extraWrite = const [],
    String agentRoot = '~/.pi',
  }) => HarnessSpec(
    name: 't',
    command: ['t'],
    agentRoot: agentRoot,
    extraRead: extraRead,
    extraWrite: extraWrite,
  );

  group('manifest sources rejected at resolve', () {
    for (final (label, read, write) in [
      ('extraRead ~/.ssh', ['~/.ssh'], null),
      ('extraRead ~/.gnupg', ['~/.gnupg'], null),
      ('extraRead ~/Library/Keychains', ['~/Library/Keychains'], null),
      ('extraRead INSIDE ~/.ssh', ['~/.ssh/config'], null),
      ('extraWrite ~/.ssh', null, ['~/.ssh']),
      ('extraWrite ~/.gnupg', null, ['~/.gnupg']),
      ('extraWrite ~/Library/Keychains/x', null, ['~/Library/Keychains/x']),
    ]) {
      test(label, () {
        expect(
          () => resolveRuntime(
            specWith(
              extraRead: read ?? const [],
              extraWrite: write ?? const [],
            ),
            services: const {},
            cwd: '/w',
            home: home,
            env: const {},
            fs: _FakeIO(),
          ),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf([contains('ungrantable'), contains('E10')]),
            ),
          ),
        );
      });
    }

    test('agentRoot itself cannot be ~/.ssh', () {
      expect(
        () => resolveRuntime(
          specWith(agentRoot: '~/.ssh'),
          services: const {},
          cwd: '/w',
          home: home,
          env: const {},
          fs: _FakeIO(),
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('env knobs (E10 escape hatch)', () {
    test('EXTRA_READ with ~/.ssh honored + warning collected', () {
      final rt = resolveRuntime(
        specWith(),
        services: const {},
        cwd: '/w',
        home: home,
        env: {'CUBE_SANDBOX_EXTRA_READ': '$home/.ssh'},
        fs: _FakeIO(),
      );
      expect(rt.extraRead, contains('$home/.ssh'));
      expect(rt.warnings, isNotEmpty);
      expect(rt.warnings.first, contains('.ssh'));
      expect(rt.warnings.first, contains('NEVER silent'));
    });

    test('EXTRA_WRITE with ~/.ssh REJECTED', () {
      expect(
        () => resolveRuntime(
          specWith(),
          services: const {},
          cwd: '/w',
          home: home,
          env: {'CUBE_SANDBOX_EXTRA_WRITE': '$home/.ssh'},
          fs: _FakeIO(),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('ordinary EXTRA_READ/EXTRA_WRITE just grant', () {
      final rt = resolveRuntime(
        specWith(),
        services: const {},
        cwd: '/w',
        home: home,
        env: {
          'CUBE_SANDBOX_EXTRA_READ': '/opt/ro',
          'CUBE_SANDBOX_EXTRA_WRITE': '/opt/rw',
        },
        fs: _FakeIO(),
      );
      expect(rt.extraRead, contains('/opt/ro'));
      expect(rt.extraWrite, contains('/opt/rw'));
      expect(rt.warnings, isEmpty);
    });
  });

  test('ungrantableViolations: both /private spellings caught', () {
    expect(ungrantableViolations(['/private/Users/dev/.ssh/id_rsa'], home), [
      '/private/Users/dev/.ssh/id_rsa',
    ]);
    expect(ungrantableViolations(['/Users/dev/.gnupg/pubring.kbx'], home), [
      '/Users/dev/.gnupg/pubring.kbx',
    ]);
    expect(
      ungrantableViolations(['/Users/dev/.ssh-wrong-name'], home),
      isEmpty,
    );
    expect(ungrantableViolations(['/opt/homebrew'], home), isEmpty);
  });

  test('shipped catalog never touches ungrantable roots', () {
    for (final g in kServiceCatalog) {
      final expanded = [
        for (final p in g.read) p.replaceFirst('~', home),
        for (final p in g.write) p.replaceFirst('~', home),
      ];
      expect(
        ungrantableViolations(expanded, home),
        isEmpty,
        reason: '--use-${g.id} grants must stay clean',
      );
    }
  });
}

final class _FakeIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
