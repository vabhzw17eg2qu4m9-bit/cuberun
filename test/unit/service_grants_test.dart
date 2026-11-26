import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:cube_sandbox/src/service_profiles.dart';
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

  test('--use-uv grants exactly the two v2-row rw dirs (#196, AC1)', () {
    final g = resolveServiceGrants({'uv'}, home: home);
    expect(
      g.read,
      isEmpty,
      reason: 'OQ2 = NO: no ro ~/.config/uv (v2 row verbatim)',
    );
    expect(g.write, ['/Users/dev/.cache/uv', '/Users/dev/.local/share/uv']);
  });

  test('--use-uv unions and dedups with --use-github; order immune (E9)', () {
    final gu = resolveServiceGrants({'github', 'uv'}, home: home);
    final ug = resolveServiceGrants({'uv', 'github'}, home: home);
    expect(gu.read, ug.read);
    expect(gu.write, ug.write);
    expect(gu.read, ['/Users/dev/.config/gh', '/Users/dev/.gitconfig']);
    expect(gu.write, ['/Users/dev/.cache/uv', '/Users/dev/.local/share/uv']);
  });

  test('uv paths never touch an ungrantable root (E10, UT-uv3)', () {
    final g = resolveServiceGrants({'uv'}, home: home);
    expect(ungrantableViolations([...g.read, ...g.write], home), isEmpty);
    expect(ungrantablePrefixViolations([...g.read, ...g.write], home), isEmpty);
  });

  test('case typo --use-uV fails closed, LOUD, catalog listed with uv', () {
    expect(
      () => resolveServiceGrants({'uV'}, home: home), // case typo, never folded
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf([
            contains('--use-uV'),
            contains('catalog: github, gitlab, nvm, uv'),
          ]),
        ),
      ),
    );
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
            contains('uv'),
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

    final ab = emitProfile(withFlags({'github', 'gitlab', 'nvm', 'uv'})).text;
    final ba = emitProfile(withFlags({'uv', 'nvm', 'gitlab', 'github'})).text;
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

  test('#196: --use-uv changes key10; same flags => same key10', () {
    HarnessRuntime mk(Set<String> flags) => HarnessRuntime(
      projDir: '/Users/dev/proj',
      agentRoot: '/Users/dev/.pi',
      tmp: '/private/var/folders/t/T1',
      extraRead: resolveServiceGrants(flags, home: home).read,
      extraWrite: resolveServiceGrants(flags, home: home).write,
    );
    final plain = emitProfile(mk({})).key10;
    final uv = emitProfile(mk({'uv'})).key10;
    expect(uv, isNot(plain), reason: 'flag set is part of the content key');
    expect(emitProfile(mk({'uv'})).key10, uv, reason: 'deterministic emit');
  });

  test('uv rw dirs are WRITE grants in the profile (reads implied)', () {
    final rt = resolveRuntime(
      HarnessSpec(name: 'pi', command: ['pi'], agentRoot: '~/.pi'),
      services: {'uv'},
      cwd: '/Users/dev/proj',
      home: home,
      env: {'HOME': home, 'TMPDIR': '/private/var/folders/t/T1'},
      fs: _FakeIO(),
    );
    final text = emitProfile(rt).text;
    expect(text, contains('(allow file-write* (subpath "$home/.cache/uv"))'));
    expect(
      text,
      contains('(allow file-write* (subpath "$home/.local/share/uv"))'),
    );
    // OQ1/OQ2 = NO: nothing outside the two rw dirs may be granted.
    expect(text.contains('.local/bin'), isFalse);
    expect(text.contains('.config/uv'), isFalse);
  });

  // --- Issue #204: services.yaml config profiles ride the --use-* stage.

  test('config profile grants apply + union with built-ins (E9 immune)', () {
    final doc = parseServiceProfiles(
      'apiVersion: cube-sandbox/v1\nservices:\n'
      '  demo:\n    read: [~/shared/notes]\n    write: [~/work/scratch]\n',
      path: 'services.yaml',
      home: home,
    );
    final ab = resolveServiceGrants(
      {'demo', 'github'},
      home: home,
      profiles: doc,
    );
    final ba = resolveServiceGrants(
      {'github', 'demo'},
      home: home,
      profiles: doc,
    );
    for (final r in [ab, ba]) {
      expect(r.read, [
        '$home/.config/gh',
        '$home/.gitconfig',
        '$home/shared/notes',
      ]);
      expect(r.write, ['$home/work/scratch']);
      expect(r.used, {'demo', 'github'});
    }
    expect(ab.read, ba.read, reason: 'flag order never matters (E9)');
  });

  test('built-in catalog wins on collision with a services.yaml entry', () {
    final doc = parseServiceProfiles(
      'apiVersion: cube-sandbox/v1\nservices:\n'
      '  github:\n    write: [/tmp/rogue]\n',
      path: 'services.yaml',
      home: home,
    );
    final r = resolveServiceGrants({'github'}, home: home, profiles: doc);
    expect(r.read, [
      '$home/.config/gh',
      '$home/.gitconfig',
    ], reason: 'catalog grants, never the rogue entry');
    expect(r.write, isEmpty);
  });

  test('config env overlay merges first-occurrence-wins (sorted names)', () {
    final doc = parseServiceProfiles(
      'apiVersion: cube-sandbox/v1\nservices:\n'
      '  a-one:\n    env:\n      SCRATCH_HOST: from-a\n'
      '  z-two:\n    env:\n      SCRATCH_HOST: from-z\n      ONLY_Z: yes\n',
      path: 'services.yaml',
      home: home,
    );
    final r = resolveServiceGrants(
      {'a-one', 'z-two'},
      home: home,
      profiles: doc,
    );
    expect(r.env, {'SCRATCH_HOST': 'from-a', 'ONLY_Z': 'yes'});
  });

  test('config write hitting a blocklisted root throws (E10)', () {
    final doc = parseServiceProfiles(
      'apiVersion: cube-sandbox/v1\nservices:\n'
      '  danger:\n    write: [~/.gnupg]\n',
      path: 'services.yaml',
      home: home,
    );
    expect(
      () => resolveServiceGrants({'danger'}, home: home, profiles: doc),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf([contains('ungrantable'), contains('$home/.gnupg')]),
        ),
      ),
    );
  });

  test('config read hitting a blocklisted root honors + warns (E10)', () {
    final doc = parseServiceProfiles(
      'apiVersion: cube-sandbox/v1\nservices:\n'
      '  danger:\n    read: [~/.gnupg]\n',
      path: 'services.yaml',
      home: home,
    );
    final r = resolveServiceGrants({'danger'}, home: home, profiles: doc);
    expect(r.read, ['$home/.gnupg'], reason: 'operator override honored');
    expect(r.warnings, hasLength(1));
    expect(r.warnings.single, contains('NEVER silent'));
  });

  test('catalog ids pinned (REG support)', () {
    expect(serviceCatalogIds, ['github', 'gitlab', 'nvm', 'uv']);
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
