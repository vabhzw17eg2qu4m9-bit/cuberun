import 'package:cube_sandbox/src/banner.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:test/test.dart';

/// Issue #69 AC4 — banner derivation is pure and truthful: rw/ro/source
/// lines are built ONLY from the resolved runtime + winning source, and
/// warnings (runtime + cache loudness) render as `⚠` lines. Unit-pinned
/// here so the CLI can never print optimism the facts don't support.
void main() {
  const spec = HarnessSpec(
    name: 'codemie',
    description: 'd',
    command: ['c'],
    agentRoot: '~/.pi/agent',
  );

  ResolvedHarness resolved({String? path}) => ResolvedHarness(
    spec: spec,
    source: path == null ? HarnessSource.preset : HarnessSource.project,
    path: path,
  );

  HarnessRuntime rt({
    List<String> extraRead = const [],
    List<String> extraWrite = const [],
    List<String> runtimeDirs = const [],
    Set<String> services = const {},
    List<String> warnings = const [],
  }) => HarnessRuntime(
    projDir: '/w/proj',
    agentRoot: '/h/.pi',
    tmp: '/private/tmp/T69',
    extraRead: extraRead,
    extraWrite: extraWrite,
    runtimeDirs: runtimeDirs,
    services: services,
    warnings: warnings,
  );

  test('base lines: header, source, rw, ro, denied — byte-pinned', () {
    expect(
      bannerLines(
        resolved: resolved(path: '/w/proj/.cube-sandbox/codemie.yaml'),
        runtime: rt(extraWrite: ['/h/.codemie']),
        key10: 'ccf00c25c5',
        profilePath: '/w/proj/.cube-sandbox/cache/harness-ccf00c25c5.sb',
      ),
      [
        '⛨ codemie under cube-sandbox '
            '(profile ccf00c25c5: '
            '/w/proj/.cube-sandbox/cache/harness-ccf00c25c5.sb)',
        '   source : .cube-sandbox/ (project) '
            '(/w/proj/.cube-sandbox/codemie.yaml)',
        '   rw     : /w/proj · /h/.pi · /private/tmp/T69 · /h/.codemie',
        '   ro     : system dirs',
        '   denied : /Users /private/var /Volumes /Network /home /net '
            '(except grants above — blanket read-deny unbuildable, E1) · '
            'all writes outside rw · network OPEN (cubes deny net inside)',
      ],
    );
  });

  test('source line falls back to the label when there is no path', () {
    expect(
      bannerLines(resolved: resolved(), runtime: rt(), key10: 'k').take(2),
      ['⛨ codemie under cube-sandbox (profile k)', '   source : preset'],
    );
  });

  test('runtime dirs and extra reads render in ro; empty stays quiet', () {
    final withDirs = bannerLines(
      resolved: resolved(),
      runtime: rt(runtimeDirs: ['/opt/homebrew/bin'], extraRead: ['/h/.cfg']),
      key10: 'k',
    );
    expect(
      withDirs[3],
      '   ro     : system dirs · runtime (/opt/homebrew/bin) · /h/.cfg',
    );
    expect(
      bannerLines(resolved: resolved(), runtime: rt(), key10: 'k')[3],
      '   ro     : system dirs',
    );
  });

  test('services render sorted on the use line; absent when none', () {
    final withUse = bannerLines(
      resolved: resolved(),
      runtime: rt(services: {'nvm', 'github'}),
      key10: 'k',
    );
    expect(withUse[5], '   use    : github, nvm');
    expect(
      bannerLines(resolved: resolved(), runtime: rt(), key10: 'k').length,
      5,
    );
  });

  test('runtime + cache warnings render last, ⚠-prefixed, in order', () {
    final lines = bannerLines(
      resolved: resolved(),
      runtime: rt(warnings: ['knob w']),
      key10: 'k',
      warnings: const [
        'same-stem profile shadowed: /u/.cube-sandbox/codemie.yaml '
            '(differs; the launcher resolves /w/proj/.cube-sandbox/codemie.yaml)',
      ],
    );
    expect(lines[lines.length - 2], startsWith('⚠  knob w'));
    expect(lines.last, startsWith('⚠  same-stem profile shadowed'));
  });

  test('deterministic: identical inputs give byte-identical banners', () {
    final a = bannerLines(
      resolved: resolved(path: '/p.yaml'),
      runtime: rt(),
      key10: 'kkkkkkkkkk',
    );
    final b = bannerLines(
      resolved: resolved(path: '/p.yaml'),
      runtime: rt(),
      key10: 'kkkkkkkkkk',
    );
    expect(a, b);
  });
}
