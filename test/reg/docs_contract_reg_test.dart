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
}
