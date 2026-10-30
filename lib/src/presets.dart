/// Built-in harness presets: manifest TEXT, parsed through the same strict
/// parser as every user file (AC2 — no drift between preset and user
/// paths, the bug class the two PoC node launchers suffered).
library;

import 'exceptions.dart';
import 'harness_manifest.dart';

/// The launchers with a preset on this machine, each with its state
/// root (`~/.claude`, `~/Library/Application Support/Claude`, `~/.fah`,
/// `~/.omp`, `~/.pi`).
final class HarnessPresets {
  /// preset id -> manifest yaml text (sorted).
  static const Map<String, String> manifests = <String, String>{
    'claude': _claude,
    'claude-desktop': _claudeDesktop,
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

  static const String _claude = '''
# Claude Code CLI (npm @anthropic-ai/claude-code — native Mach-O or node
# shebang; E5 runtime-prefix grants apply). State root ~/.claude (P2).
# The config FILE ~/.claude.json sits directly under the home directory
# and Claude Code persists it atomically with RANDOM siblings
# (.claude.json.tmp.<rand>, .claude.json.lock, .claude.json.backup) —
# literals cannot enumerate random suffixes (issue #139), so the grant
# is the SBPL string-prefix filter: ~/.claude.json itself plus every
# ~/.claude.json* sibling. CLAUDE_CONFIG_DIR overrides the root.
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: claude
  description: Claude Code CLI (state root ~/.claude)
spec:
  command: claude
  agentRoot: ~/.claude
  agentRootEnv: CLAUDE_CONFIG_DIR
  extraWritePrefix:
    - ~/.claude.json
  network: open
''';

  static const String _claudeDesktop = '''
# Claude Code desktop app — absolute argv, no PATH lookup (P6).
# --no-sandbox (issue #140): the app is Electron/Chromium and initializes
# its OWN inner sandbox in every child process (GPU, network service);
# macOS denies nested sandbox policy application under an outer seatbelt
# profile (kernel EPERM), so every child dies and the app fatal-loops
# (GPU exit 6). --no-sandbox switches off the INNER Chromium sandbox
# only — the OUTER cube kernel profile remains the single confiner for
# the whole process tree (E-note; network: open already matches app
# needs). State under ~/Library/Application Support/Claude; logs +
# caches are the starter grant set. ~/Library/Preferences rides cfprefsd
# IPC, which file-rule SBPL does not confine (E-C4, expected to work).
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: claude-desktop
  description: Claude Code desktop app (~/Library/Application Support)
spec:
  command:
    - /Applications/Claude.app/Contents/MacOS/Claude
    - --no-sandbox
  agentRoot: ~/Library/Application Support/Claude
  extraWrite:
    - ~/Library/Logs/Claude
    - ~/Library/Caches/com.anthropic.claude
  network: open
''';

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
