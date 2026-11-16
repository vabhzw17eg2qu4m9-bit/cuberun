@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #196 — E2E-uv1 (AC4): the full confined uv workflow under
/// `--use-uv` — `uv python install` → `uv venv` → `uv init`/`uv add` →
/// `uv run python` — every step exits 0 inside the boundary, the final
/// interpreter resolves to the managed copy under
/// `<home>/.local/share/uv/python`, and a post-run audit finds ZERO
/// artifacts outside the granted union (project dir + the two rw dirs).
///
/// Hermetic (OQ3): the whole launcher runs with a fixture HOME under the
/// system temp, so nothing real is ever written — no operator uv state,
/// no `~/.local/bin` entries (OQ1: deliberately not granted; uv's shim
/// warning is the loud, non-fatal UV-E5 behavior), no `~/.config/uv`
/// (OQ2: not granted). The two granted leaf dirs are pre-created empty:
/// the profile makes only the leaf subpaths writable, so uv could not
/// mkdir their parents from inside — everything INSIDE them is still
/// confined-created by uv itself.
///
/// Skips loudly when the host cannot apply profiles (agent dev cube) or
/// when uv is not installed (a skip is never silently green).
void main() {
  final String? skipKernel = h.nestedSandboxDeniedReason();

  /// Loud skip when uv is absent (e.g. a bare CI runner) — a separate
  /// color from failed, never silently green.
  final String? skipUv = () {
    final w = Process.runSync('/bin/sh', ['-c', 'command -v uv']);
    return w.exitCode == 0
        ? null
        : 'uv is not installed on this host (install e.g. `brew install '
              'uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`)';
  }();

  void kernelTest(String name, dynamic Function() body) =>
      test(name, body, skip: skipKernel ?? skipUv);

  late Directory tmp;
  late Directory home;
  late String proj;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-uv-');
    home = Directory.systemTemp.createTempSync('cube-sandbox-uv-home-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));
    proj = '${tmp.path}/proj';
    Directory('$proj/.cube-sandbox').createSync(recursive: true);
    Directory('${tmp.path}/t').createSync();
    Directory('${home.path}/.cache/uv').createSync(recursive: true);
    Directory('${home.path}/.local/share/uv').createSync(recursive: true);

    // The confined workflow: one fail-fast script; the profile drives it.
    File('${tmp.path}/flow.sh').writeAsStringSync('''
set -e
cd "\$PROJ"
uv python install 3.12
uv venv .venv --python 3.12
uv init --name demo --bare
uv add requests
uv run python -c 'import requests, sys; print(sys.base_prefix)'
''');
    File('$proj/.cube-sandbox/uvflow.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: uvflow
spec:
  command:
    - /bin/sh
    - ${tmp.path}/flow.sh
  agentRoot: $proj
''');
  });

  Map<String, String> env() => {
    'HOME': home.path,
    'PROJ': proj,
    'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
    'TMPDIR': '${tmp.path}/t',
  };

  kernelTest('E2E-uv1/AC4: confined uv workflow end to end (fixture HOME)', () {
    final r = h.launchCubeSandbox(
      ['launch', '--wait', '--use-uv', 'uvflow'],
      cwd: proj,
      env: env(),
    );
    expect(r.exit, 0, reason: 'every confined step must exit 0:\n${r.stderr}');

    // The venv's base interpreter is the MANAGED copy inside the granted
    // data dir (F2) — not a system python reached around the boundary.
    expect(r.stdout, contains('${home.path}/.local/share/uv/python'));

    // Post-run audit: nothing outside the granted union. The fixture home
    // may contain ONLY the two granted trees (uv never reached
    // ~/.local/bin, ~/.config, ~/Library — F5/F7 byte-audit).
    final allowed = ['${home.path}/.cache/uv', '${home.path}/.local/share/uv'];
    final stray = home
        .listSync(recursive: true, followLinks: false)
        .map((e) => e.path)
        .where((p) => !allowed.any((a) => p == a || p.startsWith('$a/')))
        .toList();
    expect(stray, isEmpty, reason: 'writes escaped the granted union');
  });

  kernelTest(
    'E2E-uv1b/AC4: same flags => one key10, staged profile reused',
    () {
      final first = h.launchCubeSandbox(
        ['launch', '--wait', '--use-uv', 'uvflow'],
        cwd: proj,
        env: env(),
      );
      expect(first.exit, 0);

      Iterable<File> sbFiles() => Directory(
        '$proj/.cube-sandbox/cache',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.sb'));
      expect(sbFiles(), hasLength(1), reason: 'one flag set => one key10');

      // Identical relaunch: same content key, staged profile reused,
      // harness green again — no second key ever staged (#69 discipline).
      final second = h.launchCubeSandbox(
        ['launch', '--wait', '--use-uv', 'uvflow'],
        cwd: proj,
        env: env(),
      );
      expect(second.exit, 0);
      expect(sbFiles(), hasLength(1));
    },
  );
}
