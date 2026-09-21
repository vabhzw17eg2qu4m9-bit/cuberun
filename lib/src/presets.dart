/// Built-in harness presets: manifest TEXT, parsed through the same strict
/// parser as every user file (AC2 — no drift between preset and user
/// paths, the bug class the two PoC node launchers suffered).
library;

import 'exceptions.dart';
import 'harness_manifest.dart';

/// The three launchers that exist on this machine today, each with its
/// state root (`~/.pi`, `~/.omp`, `~/.fah`).
final class HarnessPresets {
  /// preset id -> manifest yaml text (sorted: fa, omp, pi).
  static const Map<String, String> manifests = <String, String>{
    'fa': _fa,
    'omp': _omp,
    'pi': _pi,
  };

  const HarnessPresets._();

  /// Preset ids, sorted.
  static List<String> get ids => manifests.keys.toList()..sort();

  /// Whether [id] names a built-in preset.
  static bool has(String id) => manifests.containsKey(id);

  /// Parses preset [id] through the strict parser. [ConfigException] on
  /// unknown id (caller usually wants `resolveHarness` instead).
  static HarnessSpec load(String id) {
    final text = manifests[id];
    if (text == null) {
      throw ConfigException('no preset "$id" (presets: ${ids.join(', ')})');
    }
    return HarnessSpec.fromYamlText(text, sourcePath: '<preset:$id>');
  }

  /// Parses every preset — used by UT/REG to prove all three stay valid.
  static Map<String, HarnessSpec> loadAll() => {
    for (final id in ids) id: load(id),
  };

  static const String _fa = '''
# fa coding agent — state root ~/.fah (no agentRootEnv upstream yet).
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: fa
  description: fa coding agent (state root ~/.fah)
spec:
  command: fa
  agentRoot: ~/.fah
  network: open
''';

  static const String _omp = '''
# omp launcher — state root ~/.omp (OMP_AGENT_DIR overrides).
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: omp
  description: omp launcher (state root ~/.omp)
spec:
  command: omp
  agentRoot: ~/.omp
  agentRootEnv: OMP_AGENT_DIR
  network: open
''';

  static const String _pi = '''
# pi coding agent — state dir ~/.pi/agent widened to ~/.pi
# (skills/themes/keybindings live next to agent state).
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: pi
  description: pi coding agent (state root ~/.pi)
spec:
  command: pi
  agentRoot: ~/.pi/agent
  agentRootEnv: PI_CODING_AGENT_DIR
  widenToDotParent: true
  network: open
''';
}
