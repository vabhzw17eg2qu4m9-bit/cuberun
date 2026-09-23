import 'dart:io';

import 'package:test/test.dart';

/// REG-2 (issue #69) — the cache contract is DOCUMENTED: the clean
/// command, its between-sessions caveat, and the invalidation/provenance
/// semantics live in README + docs/config.md + the agent skill. A docs
/// regression is a red build, like any confinement drift.
void main() {
  final root = Directory.current.path;

  String read(String rel) => File('$root/$rel').readAsStringSync();

  test('README documents cube-sandbox clean + between-sessions caveat', () {
    final readme = read('README.md');
    expect(readme, contains('cube-sandbox clean'));
    expect(readme, contains('between sessions'));
  });

  test('README documents cache invalidation (rebuild on source change)', () {
    final readme = read('README.md');
    expect(readme, contains('rebuilt'));
    expect(readme, contains('provenance'));
  });

  test('docs/config.md documents the cache, provenance stamps and clean', () {
    final config = read('docs/config.md');
    expect(config, contains('.src'));
    expect(config, contains('clean'));
    expect(config, contains('between sessions'));
    expect(config, contains('shadowed'));
  });

  test('agent skill mentions the clean command and rebuild semantics', () {
    final skill = read('skills/cube-sandbox-config/SKILL.md');
    expect(skill, contains('clean'));
    expect(skill, contains('rebuild'));
  });

  // --- Issue #81: terminal control + cache-key hygiene are documented.

  test('README documents the tty foreground-hold and --spawn-exit opt-out', () {
    final readme = read('README.md');
    expect(readme, contains('--spawn-exit'));
    expect(readme, contains('raw mode'));
    expect(readme, contains('CUBE_SANDBOX_SPAWN_LOG'));
  });

  test('README documents the manual raw-mode repro for a real terminal', () {
    final readme = read('README.md');
    expect(readme, contains('setRawMode EIO'));
    expect(readme, contains('Manual repro'));
  });

  test('docs/config.md documents key10 inputs vs volatile argv', () {
    final config = read('docs/config.md');
    expect(config, contains('--session'));
    expect(config, contains('foreground-hold'));
    expect(config, contains('CUBE_SANDBOX_SPAWN_LOG'));
  });

  test('docs pin the from-tty --spawn-exit hazard (headless-shape only)', () {
    // From a terminal, --spawn-exit hands the tty back immediately and
    // Unix tears the orphan's session down on pty master close — the
    // documented v0.3.1 raw-mode hazard (#81). The docs must say it is
    // for headless-shape automation, not TUIs.
    final readme = read('README.md');
    expect(
      readme,
      contains('headless-shape automation'),
      reason: 'README automation note must pin the from-tty hazard',
    );
    expect(
      readme,
      contains('not TUIs'),
      reason: 'README automation note must exclude TUIs from --spawn-exit',
    );
    final config = read('docs/config.md');
    expect(
      config,
      contains('the v0.3.1 raw-mode hazard #81'),
      reason: 'config.md terminal section must pin the from-tty hazard',
    );
  });
}
