import 'package:cube_sandbox/src/harness_manifest.dart';
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
}

final class _NoIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
