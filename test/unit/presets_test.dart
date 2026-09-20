import 'package:cuberun/src/exceptions.dart';
import 'package:cuberun/src/presets.dart';
import 'package:test/test.dart';

/// AC2 — exactly fa, omp, pi ship; each parses through the SAME strict
/// parser with its own agent root.
void main() {
  test('preset ids are exactly fa, omp, pi', () {
    expect(HarnessPresets.ids, ['fa', 'omp', 'pi']);
  });

  test('all presets parse through the strict parser', () {
    final all = HarnessPresets.loadAll();
    expect(all.keys, ['fa', 'omp', 'pi']);
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
}
