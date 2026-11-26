import 'dart:io';

import 'package:cube_sandbox/src/agents_md.dart' show generateAgentsMd;
import 'package:cube_sandbox/src/service_grants.dart' show kServiceCatalog;
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

  test(
    'README documents the tty exec (zero resident launcher) and --wait opt-in',
    () {
      final readme = read('README.md');
      expect(readme, contains('zero resident launcher'));
      expect(readme, contains("--wait"));
      expect(readme, contains('raw mode'));
      expect(readme, contains('CUBE_SANDBOX_SPAWN_LOG'));
    },
  );

  test('README documents the manual raw-mode repro for a real terminal', () {
    final readme = read('README.md');
    expect(readme, contains('setRawMode EIO'));
    expect(readme, contains('Manual repro'));
  });

  test('docs/config.md documents key10 inputs vs volatile argv', () {
    final config = read('docs/config.md');
    expect(config, contains('--session'));
    expect(config, contains('zero resident launcher'));
    expect(config, contains('CUBE_SANDBOX_SPAWN_LOG'));
  });

  test(
    'docs pin the tty-attached automation path (headless shape, /dev/null stdin)',
    () {
      // Since #113 the tty default (and --spawn-exit) is exec; fire-and-
      // forget automation must redirect stdin from /dev/null to get the
      // headless spawn-and-exit shape. The pre-#113 hazard stays pinned
      // as history in config.md.
      final readme = read('README.md');
      expect(
        readme,
        contains('stdin redirected from /dev/null'),
        reason:
            'README automation note must pin the headless shape for fire-and-forget',
      );
      expect(
        readme,
        contains('--spawn-exit'),
        reason: 'README must state --spawn-exit execs from a terminal now',
      );
      final config = read('docs/config.md');
      expect(
        config,
        contains('the v0.3.1 raw-mode hazard #81'),
        reason:
            'config.md terminal section must pin the pre-#113 hazard as history',
      );
    },
  );

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

  // --- Issue #204: AGENTS.md manual + services.yaml data-driven profiles.

  test('README documents services.yaml custom service profiles', () {
    final readme = read('README.md');
    expect(readme, contains('services.yaml'));
    expect(readme, contains('apiVersion: cube-sandbox/v1'));
    expect(readme, contains('built-in catalog wins on name collision'));
    expect(readme, contains('SCRATCH_HOST'));
  });

  test('README documents the AGENTS.md manual and the init verb', () {
    final readme = read('README.md');
    expect(readme, contains('~/.cube-sandbox/AGENTS.md'));
    expect(readme, contains('cube-sandbox init'));
    expect(readme, contains('write-if-missing'));
    expect(readme, contains('--force'));
  });

  test('docs/config.md documents services.yaml end to end', () {
    final config = read('docs/config.md');
    expect(config, contains('Custom service profiles (`services.yaml`'));
    expect(config, contains('~/.cube-sandbox/services.yaml'));
    expect(config, contains('naming the file AND line'));
    expect(config, contains('the built-in catalog WINS on name collision'));
    expect(config, contains('services →\n  folder groups'));
    expect(config, contains('services.yaml carries blocklisted read path'));
  });

  test('docs/config.md documents the AGENTS.md manual refresh policy', () {
    final config = read('docs/config.md');
    expect(config, contains('~/.cube-sandbox/AGENTS.md'));
    expect(config, contains('init [--force]'));
    expect(config, contains('only overwrite seam'));
  });

  test('agent skill mentions services.yaml and the AGENTS.md manual', () {
    final skill = read('skills/cube-sandbox-config/SKILL.md');
    expect(skill, contains('services.yaml'));
    expect(skill, contains('AGENTS.md'));
    expect(skill, contains('init --force'));
  });

  test(
    'AGENTS.md generator: every usage verb and flag appears in the text (AC10)',
    () {
      final text = generateAgentsMd();
      for (final verb in [
        'launch',
        'list',
        'init',
        'show',
        'sbpl',
        'new',
        'clean',
        'probe',
      ]) {
        expect(text, contains(verb), reason: 'verb "$verb" missing');
      }
      for (final flag in [
        '--file',
        '--yaml',
        '--use-',
        '--folders',
        '--wait',
        '--spawn-exit',
        '--command',
        '--agent-root',
        '--force',
        '--help',
        '--version',
      ]) {
        expect(text, contains(flag), reason: 'flag "$flag" missing');
      }
    },
  );

  test('AGENTS.md generator passes the secret scan (AC10)', () {
    for (final s in [
      'sk-ant-',
      'ghp_',
      'xoxb-',
      'AKIA',
      '[REDACTED:',
      'hunter2',
      'BEGIN PRIVATE KEY',
      'token:',
    ]) {
      expect(generateAgentsMd(), isNot(contains(s)));
    }
  });

  test('AGENTS.md pins the dot-dir, schema and safety tokens (AC5-AC9)', () {
    final text = generateAgentsMd();
    // AC5 — layout + precedence + clean.
    for (final t in [
      '<name>.yaml',
      'folders.yaml',
      '.cube-sandbox/cache',
      'harness-<key10>',
      '.src',
      '`cube-sandbox clean`',
      '`--file` > `<cwd>/.cube-sandbox/<name>.yaml` >',
    ]) {
      expect(text, contains(t), reason: 'AC5 token missing: $t');
    }
    // AC6 — new verb + manifest schema.
    for (final t in [
      'cube-sandbox new <name> --command',
      '--agent-root',
      'apiVersion: cube-sandbox/v1',
      'extraWritePrefix',
      'network: open',
      'unknown key at ANY level',
    ]) {
      expect(text, contains(t), reason: 'AC6 token missing: $t');
    }
    // AC7 — the REAL catalog (derived) + fail-closed + extension seam.
    for (final g in kServiceCatalog) {
      expect(text, contains('--use-${g.id}'), reason: 'AC7 id');
      for (final p in [...g.read, ...g.write]) {
        expect(text, contains(p), reason: 'AC7 grant of ${g.id}: $p');
      }
    }
    expect(text, contains('fails closed'));
    expect(text, contains('kServiceCatalog'));
    expect(text, contains('lib/src/service_grants.dart'));
    // services.yaml schema, workflow, precedence, troubleshooting.
    for (final t in [
      'services.yaml',
      'SCRATCH_HOST',
      'apiVersion: cube-sandbox/v1',
      'show <profile> --use-scratch',
      'launch --use-scratch',
      'deleting its entry',
      'BUILT-IN catalog wins on name collision',
      'first\noccurrence wins',
      'Troubleshooting',
      'services.yaml:<line>',
    ]) {
      expect(text, contains(t), reason: 'services.yaml doc missing: $t');
    }
    // AC8 — folder groups.
    for (final t in [
      'groups:',
      '--folders projecta',
      '[a-z0-9][a-z0-9-]*',
      'rejected (exit 2)',
      'loud warning banner',
      'CUBE_SANDBOX_EXTRA_READ',
      'CUBE_SANDBOX_EXTRA_WRITE',
    ]) {
      expect(text, contains(t), reason: 'AC8 token missing: $t');
    }
    // AC9 — safety.
    for (final t in [
      'Never hand-edit a staged cache profile',
      'while a confined\n  session launched from it is running',
      'between sessions',
      'NEVER grantable',
      'never forbid commands',
    ]) {
      expect(text, contains(t), reason: 'AC9 token missing: $t');
    }
  });
}
