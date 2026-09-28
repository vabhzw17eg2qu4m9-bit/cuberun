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

  // --- Issue #101: per-run folder groups (--folders) are documented.

  test('README documents folder groups: schema, selection, key10 inputs', () {
    final readme = read('README.md');
    expect(readme, contains('Folder groups (`--folders`)'));
    expect(readme, contains('folders.yaml'));
    expect(readme, contains('--folders projectA,projectB'));
    // key10-inputs list gains the selection.
    expect(readme, contains('selected folder groups'));
    // The writes allow-list sentence names folder groups.
    expect(readme, contains('folder groups (`--folders`)'));
  });

  test(
    'README escape-hatch wording stays truthful with two loud read paths',
    () {
      final readme = read('README.md');
      // No longer "the single" escape hatch: blocklisted folder-group reads
      // are honored too, equally loud.
      expect(readme, isNot(contains('single operator escape hatch')));
      expect(readme, contains('operator escape hatches'));
    },
  );

  test('docs/config.md documents folder groups end to end', () {
    final config = read('docs/config.md');
    // Source-of-truth list gains the module.
    expect(config, contains('folder_groups.dart'));
    // argv-contract sentence gains --folders.
    expect(config, contains('--folders'));
    // Precedence-vs-layering note.
    expect(config, contains('LAYERS'));
    // Grants-merge order gains folder groups before env knobs.
    expect(config, contains('folder groups → env knobs'));
    // Ungrantable per-source coverage names the folder-groups direction.
    expect(config, contains('folder groups'));
    // The groups file schema section exists.
    expect(config, contains('~/.cube-sandbox/folders.yaml'));
  });

  test('agent skill covers the groups file and the --folders flag', () {
    final skill = read('skills/cube-sandbox-config/SKILL.md');
    expect(skill, contains('--folders'));
    expect(skill, contains('folders.yaml'));
    expect(skill, contains('sbpl'));
  });
}
