@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC-C6 / AC-C8 — Claude Code presets at the live boundary:
/// - `probe claude` + `claude --version` inside the profile where the CLI
///   exists (CI installs it via npm, P5); explicit skip-with-reason where
///   it does not — never silently green (AC13 pattern).
/// - `launch claude-desktop` fail-closes when the app bundle is absent —
///   non-zero + a diagnostic naming the missing image, nothing unconfined,
///   no raw crash (P6); skip-with-reason on a host that HAS the app.
/// - `sbpl claude-desktop` / `show claude-desktop` work everywhere without
///   the app installed (AC-C8 UT+E2E-absent case).
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  const bundle = '/Applications/Claude.app';

  /// stderr lines that indicate the profile itself denied something
  /// (deprecation warnings tolerated, E3).
  List<String> denialish(String stderr) => stderr
      .split('\n')
      .where(
        (l) =>
            l.contains('Operation not permitted') ||
            l.contains('sandbox denial') ||
            (l.toLowerCase().contains('sandbox') &&
                !l.contains('deprecated') &&
                !l.contains('profile ')),
      )
      .toList();

  test(
    'AC-C6: probe claude green + claude --version runs inside the profile',
    () {
      final which = Process.runSync('/usr/bin/which', ['claude']);
      if (which.exitCode != 0) {
        markTestSkipped(
          'claude CLI not on PATH (P5: not preinstalled) — skipped with '
          'reason, never silently green',
        );
        return;
      }
      final proj = Directory.systemTemp.createTempSync('cube-sandbox-claude-');
      addTearDown(() => proj.deleteSync(recursive: true));

      final probe = h.launchCubeSandbox(['probe', 'claude'], cwd: proj.path);
      expect(probe.exit, 0, reason: 'stderr: ${probe.stderr}');
      expect(denialish(probe.stderr), isEmpty, reason: probe.stderr);

      final version = h.launchCubeSandbox([
        'launch',
        'claude',
        '--',
        'claude',
        '--version',
      ], cwd: proj.path);
      expect(version.exit, 0, reason: 'stderr: ${version.stderr}');
      expect(
        RegExp(r'\d+\.\d+').hasMatch(version.stdout),
        isTrue,
        reason: 'claude --version output: ${version.stdout}',
      );
      expect(denialish(version.stderr), isEmpty, reason: version.stderr);
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  test(
    'AC-C8: launch claude-desktop fail-closes when the bundle is absent',
    () {
      if (Directory(bundle).existsSync()) {
        markTestSkipped(
          'Claude.app IS installed on this host — a GUI launch is not driven '
          'by tests (P6: behavioral battery is second tier, after first run)',
        );
        return;
      }
      final proj = Directory.systemTemp.createTempSync('cube-sandbox-cldd-');
      addTearDown(() => proj.deleteSync(recursive: true));

      // --wait: the blocking shape surfaces the backend's verdict for the
      // missing image (spawn-and-exit reports spawn status only, #53).
      final r = h.launchCubeSandbox([
        'launch',
        '--wait',
        'claude-desktop',
      ], cwd: proj.path);
      expect(r.exit, isNot(0), reason: 'absent bundle must not "succeed"');
      final diag = '${r.stderr}${r.stdout}';
      expect(diag, contains('Claude'), reason: diag);
    },
    skip: hostGuard ?? false,
  );

  test('AC-C8: sbpl/show claude-desktop work everywhere, app not needed', () {
    final proj = Directory.systemTemp.createTempSync('cube-sandbox-clsbpl-');
    addTearDown(() => proj.deleteSync(recursive: true));

    final sbpl = h.launchCubeSandbox([
      'sbpl',
      'claude-desktop',
    ], cwd: proj.path);
    expect(sbpl.exit, 0, reason: 'stderr: ${sbpl.stderr}');
    expect(sbpl.stdout, startsWith('(version 1)'));
    expect(
      sbpl.stdout,
      contains('(allow file-write* (subpath "'),
      reason: 'emitted profile carries the grant set',
    );

    final show = h.launchCubeSandbox([
      'show',
      'claude-desktop',
    ], cwd: proj.path);
    expect(show.exit, 0, reason: 'stderr: ${show.stderr}');
  });
}
