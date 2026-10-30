import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// AC2/AC-C1 — exactly claude, claude-desktop, fa, omp, pi ship; each
/// parses through the SAME strict parser with its own grant set.
void main() {
  const home = '/Users/dev';

  HarnessRuntime resolve(String id, {Map<String, String> env = const {}}) =>
      resolveRuntime(
        HarnessPresets.load(id),
        services: const {},
        cwd: '/Users/dev/proj',
        home: home,
        env: {'HOME': home, ...env},
      );

  test('preset ids are exactly claude, claude-desktop, fa, omp, pi', () {
    expect(HarnessPresets.ids, ['claude', 'claude-desktop', 'fa', 'omp', 'pi']);
  });

  test('all presets parse through the strict parser', () {
    final all = HarnessPresets.loadAll();
    expect(all.keys, ['claude', 'claude-desktop', 'fa', 'omp', 'pi']);
  });

  test('claude: command claude, agentRoot ~/.claude, CLAUDE_CONFIG_DIR', () {
    final claude = HarnessPresets.load('claude');
    expect(claude.command, ['claude']);
    expect(claude.agentRoot, '~/.claude');
    expect(claude.agentRootEnv, 'CLAUDE_CONFIG_DIR');
    expect(claude.widenToDotParent, isFalse);
    expect(claude.extraWrite, ['~/.claude.json', '~/.claude.json.backup']);
  });

  test('claude-desktop: absolute argv, app-support root, starter grants', () {
    final d = HarnessPresets.load('claude-desktop');
    expect(d.command, ['/Applications/Claude.app/Contents/MacOS/Claude']);
    expect(d.agentRoot, '~/Library/Application Support/Claude');
    expect(d.agentRootEnv, isNull);
    expect(d.widenToDotParent, isFalse);
    expect(d.extraWrite, [
      '~/Library/Logs/Claude',
      '~/Library/Caches/com.anthropic.claude',
    ]);
  });

  test('fa: command fa, agentRoot ~/.fah, no agentRootEnv', () {
    final fa = HarnessPresets.load('fa');
    expect(fa.command, ['fa']);
    expect(fa.agentRoot, '~/.fah');
    expect(fa.agentRootEnv, isNull);
    expect(fa.widenToDotParent, isFalse);
  });

  test('omp: command omp, agentRoot ~/.omp, OMP_AGENT_DIR override', () {
    final omp = HarnessPresets.load('omp');
    expect(omp.command, ['omp']);
    expect(omp.agentRoot, '~/.omp');
    expect(omp.agentRootEnv, 'OMP_AGENT_DIR');
  });

  test('pi: command pi, ~/.pi/agent widened to ~/.pi at runtime', () {
    final pi = HarnessPresets.load('pi');
    expect(pi.command, ['pi']);
    expect(pi.agentRoot, '~/.pi/agent');
    expect(pi.agentRootEnv, 'PI_CODING_AGENT_DIR');
    expect(pi.widenToDotParent, isTrue);
  });

  test('unknown preset fails loudly', () {
    expect(() => HarnessPresets.load('nope'), throwsA(isA<ConfigException>()));
  });

  test('AC-C2: claude.json + .backup resolve into write allows', () {
    final rt = resolve('claude');
    expect(rt.agentRoot, '$home/.claude');
    expect(rt.extraWrite, ['$home/.claude.json', '$home/.claude.json.backup']);
    final text = emitProfile(rt).text;
    expect(
      text,
      contains('(allow file-write* (subpath "$home/.claude.json"))'),
    );
    expect(
      text,
      contains('(allow file-write* (subpath "$home/.claude.json.backup"))'),
    );
  });

  test('AC-C2: claude config files are absent from the read denies', () {
    final text = emitProfile(resolve('claude')).text;
    final denyLines = text
        .split('\n')
        .where((l) => l.startsWith('(deny file-read'))
        .toList();
    expect(denyLines, isNotEmpty);
    for (final line in denyLines) {
      expect(line, isNot(contains('.claude.json')), reason: line);
    }
  });

  test('AC-C2: CLAUDE_CONFIG_DIR override honored at resolve', () {
    final rt = resolve(
      'claude',
      env: {'CLAUDE_CONFIG_DIR': '$home/.claude/states'},
    );
    expect(rt.agentRoot, '$home/.claude/states');
  });

  test('E-C2: override outside ~/.claude honored verbatim, key10 moves', () {
    final rt = resolve('claude', env: {'CLAUDE_CONFIG_DIR': '$home/proj/st'});
    expect(rt.agentRoot, '$home/proj/st');
    final defaultKey = emitProfile(resolve('claude')).key10;
    final overriddenKey = emitProfile(rt).key10;
    expect(overriddenKey, isNot(defaultKey));
  });

  test('AC-C3: claude-desktop grants land in the emitted profile', () {
    final rt = resolve('claude-desktop');
    expect(rt.agentRoot, '$home/Library/Application Support/Claude');
    final text = emitProfile(rt).text;
    expect(
      text,
      contains(
        '(allow file-write* '
        '(subpath "$home/Library/Application Support/Claude"))',
      ),
    );
    expect(
      text,
      contains('(allow file-write* (subpath "$home/Library/Logs/Claude"))'),
    );
    expect(
      text,
      contains(
        '(allow file-write* '
        '(subpath "$home/Library/Caches/com.anthropic.claude"))',
      ),
    );
  });
}
