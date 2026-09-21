import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:test/test.dart';

/// AC10 (UT) — service grants: EXACTLY the cataloged folders, union+dedup,
/// unknown service fails closed listing the catalog, key10 sensitivity.
/// E9 — flag order never changes the emitted text; repeated flags dedup.
void main() {
  const home = '/Users/dev';

  test('--use-github adds exactly the cataloged read grants', () {
    final g = resolveServiceGrants({'github'}, home: home);
    expect(g.read, ['/Users/dev/.config/gh', '/Users/dev/.gitconfig']);
    expect(g.write, isEmpty);
  });

  test('--use-gitlab unions and DEDUPS ~/.gitconfig with --use-github', () {
    final both = resolveServiceGrants({'github', 'gitlab'}, home: home);
    expect(both.read, contains('/Users/dev/.gitconfig'));
    expect(both.read.where((p) => p == '/Users/dev/.gitconfig'), hasLength(1));
    expect(
      both.read,
      containsAll(['/Users/dev/.config/gh', '/Users/dev/.config/glab']),
    );
  });

  test('--use-nvm grants the whole nvm root read-only', () {
    final g = resolveServiceGrants({'nvm'}, home: home);
    expect(g.read, ['/Users/dev/.nvm']);
  });

  test('unknown service fails closed, LOUD, catalog listed (E9)', () {
    expect(
      () => resolveServiceGrants({'gihub'}, home: home), // typo
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf([
            contains('--use-gihub'),
            contains('github'),
            contains('gitlab'),
            contains('nvm'),
          ]),
        ),
      ),
    );
  });

  test('E9: flag ORDER never changes the emitted profile text', () {
    HarnessRuntime withFlags(Set<String> flags) => HarnessRuntime(
      projDir: '/Users/dev/proj',
      agentRoot: '/Users/dev/.pi',
      tmp: '/private/var/folders/t/T1',
      extraRead: resolveServiceGrants(flags, home: home).read,
      extraWrite: resolveServiceGrants(flags, home: home).write,
    );

    final ab = emitProfile(withFlags({'github', 'gitlab', 'nvm'})).text;
    final ba = emitProfile(withFlags({'nvm', 'gitlab', 'github'})).text;
    expect(ab, ba);
  });

  test('E9: repeated flags dedup (same text as single flag)', () {
    HarnessRuntime mk(Set<String> flags) => HarnessRuntime(
      projDir: '/Users/dev/proj',
      agentRoot: '/Users/dev/.pi',
      tmp: '/private/var/folders/t/T1',
      extraRead: resolveServiceGrants(flags, home: home).read,
    );

    final duplicated = <String>{
      ...<String>['github', 'github'],
    };
    expect(emitProfile(mk(duplicated)).text, emitProfile(mk({'github'})).text);
  });

  test('AC4: grant flags change key10', () {
    final plain = emitProfile(
      HarnessRuntime(
        projDir: '/Users/dev/proj',
        agentRoot: '/Users/dev/.pi',
        tmp: '/private/var/folders/t/T1',
      ),
    ).key10;
    final granted = emitProfile(
      HarnessRuntime(
        projDir: '/Users/dev/proj',
        agentRoot: '/Users/dev/.pi',
        tmp: '/private/var/folders/t/T1',
        extraRead: resolveServiceGrants({'github'}, home: home).read,
      ),
    ).key10;
    expect(granted, isNot(plain));
  });

  test('service grants are READ-ONLY in the profile (no write allows)', () {
    final rt = resolveRuntime(
      HarnessSpec(name: 'pi', command: ['pi'], agentRoot: '~/.pi'),
      services: {'github'},
      cwd: '/Users/dev/proj',
      home: home,
      env: {'HOME': home, 'TMPDIR': '/private/var/folders/t/T1'},
      fs: _FakeIO(),
    );
    final text = emitProfile(rt).text;
    final ghWrites = text
        .split('\n')
        .where((l) => l.contains('file-write') && l.contains('.config/gh'));
    expect(ghWrites, isEmpty);
    expect(text, contains('(allow file-read* (subpath "$home/.config/gh"))'));
  });

  test('catalog ids pinned (REG support)', () {
    expect(serviceCatalogIds, ['github', 'gitlab', 'nvm']);
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
