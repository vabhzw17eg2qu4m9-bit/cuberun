import 'package:cube_sandbox/src/cache_policy.dart';
import 'package:cube_sandbox/src/folder_groups.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// REG — staged/emitted profiles contain PATHS ONLY: no env values, no
/// tokens, no secrets ever enter the SBPL text (byte-scan).
void main() {
  test('env sentinel values never appear in the profile text', () {
    const sentinels = [
      '[REDACTED:Sensitive Value]',
      'sk-ant-api03-SECRETSECRETSECRET',
      'ghp_16charSTOKENvalue',
      'hunter2-password',
    ];
    final spec = HarnessSpec(
      name: 't',
      command: ['t'],
      agentRoot: '~/.t',
      extraRead: const ['~/.config/t'],
      extraWrite: const ['/tmp/t-cache'],
    );
    final rt = resolveRuntime(
      spec,
      services: const {},
      cwd: '/w',
      home: '/Users/dev',
      env: {
        'TMPDIR': '/private/var/folders/t/T1',
        'ANTHROPIC_API_KEY': sentinels[1],
        'GITHUB_TOKEN': sentinels[2],
        'PASSWORD': sentinels[3],
        'WEIRD': sentinels[0],
        'CUBE_SANDBOX_EXTRA_READ': '/opt/clean',
      },
      fs: _NoIO(),
    );
    final text = emitProfile(rt).text;
    for (final s in sentinels) {
      expect(text, isNot(contains(s)));
    }
  });

  test('key10 derives from text only — env size does not leak into it', () {
    HarnessSpec mk() =>
        const HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t');
    final a = emitProfile(
      resolveRuntime(
        mk(),
        services: const {},
        cwd: '/w',
        home: '/Users/dev',
        env: {'TMPDIR': '/private/var/folders/t/T1'},
        fs: _NoIO(),
      ),
    );
    final b = emitProfile(
      resolveRuntime(
        mk(),
        services: const {},
        cwd: '/w',
        home: '/Users/dev',
        env: {'TMPDIR': '/private/var/folders/t/T1', 'HUGE_SECRET': 'x' * 4096},
        fs: _NoIO(),
      ),
    );
    expect(a.key10, b.key10);
    expect(a.text, b.text);
  });

  test(
    'folder-group selections keep the profile byte-scan clean (issue #101)',
    () {
      const sentinels = [
        '[REDACTED:Sensitive Value]',
        'sk-ant-api03-SECRETSECRETSECRET',
        'ghp_16charSTOKENvalue',
        'hunter2-password',
      ];
      final doc = parseFolderGroups(
        'apiVersion: cube-sandbox/v1\ngroups:\n'
        '  g:\n'
        '    write: [/tmp/g-cache]\n'
        '    read: [~/.config/g]\n',
        path: '/Users/dev/.cube-sandbox/folders.yaml',
        home: '/Users/dev',
      );
      final s = resolveFolderGroups(doc, ['g'], home: '/Users/dev');
      final rt = resolveRuntime(
        const HarnessSpec(
          name: 't',
          command: ['t'],
          agentRoot: '~/.t',
          extraRead: ['~/.config/t'],
          extraWrite: ['/tmp/t-cache'],
        ),
        services: const {},
        cwd: '/w',
        home: '/Users/dev',
        env: {
          'TMPDIR': '/private/var/folders/t/T1',
          'ANTHROPIC_API_KEY': sentinels[1],
          'GITHUB_TOKEN': sentinels[2],
          'PASSWORD': sentinels[3],
          'WEIRD': sentinels[0],
        },
        fs: _NoIO(),
        folderRead: s.read,
        folderWrite: s.write,
      );
      final profile = emitProfile(rt);
      for (final secret in sentinels) {
        expect(profile.text, isNot(contains(secret)));
      }
      // The .src stamp names groups + paths only — env values never enter it.
      final stamp = sourceStamp(
        const ResolvedHarness(
          spec: HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
          source: HarnessSource.yaml,
          sourceText: 'manifest',
        ),
        folderStamp: folderGroupsStamp(s.groups),
      );
      expect(stamp.detail, contains('folders.g'));
      for (final secret in sentinels) {
        expect('${stamp.fp}  ${stamp.detail}', isNot(contains(secret)));
      }
    },
  );
}

final class _NoIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
