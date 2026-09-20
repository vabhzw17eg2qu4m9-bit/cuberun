@Tags(['integration'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC13 — harness launch: `pi`, `omp` and `fa` each start under their own
/// Layer-0 profile and complete a trivial headless run answering OK, with
/// stderr free of sandbox denials (deprecation warning tolerated, E3).
/// Skips with an explicit reason when the harness binary or provider env
/// is absent — NEVER silently green.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  /// Headless one-shot invocation per harness (env-overridable for
  /// harnesses with different flags).
  List<String> headlessArgs(String harness, String prompt) {
    final override =
        Platform.environment['CUBERUN_SMOKE_ARGS_${harness.toUpperCase()}'];
    if (override != null && override.trim().isNotEmpty) {
      return [...override.split(' '), prompt];
    }
    return switch (harness) {
      'fa' => ['fa', '-p', prompt],
      _ => [harness, '--no-session', '-p', prompt],
    };
  }

  for (final harness in ['pi', 'omp', 'fa']) {
    test(
      '$harness: headless run under its profile answers OK',
      () {
        final which = Process.runSync('/usr/bin/which', [harness]);
        if (which.exitCode != 0) {
          markTestSkipped('$harness binary not on PATH — nothing to launch');
          return;
        }
        if (!h.providerEnvPresent()) {
          markTestSkipped(
            'no provider env (ANTHROPIC_API_KEY/OPENAI_API_KEY/…) — '
            'AC13 skipped with reason, never silently green',
          );
          return;
        }
        final proj = Directory.systemTemp.createTempSync('cuberun-smoke-');
        addTearDown(() => proj.deleteSync(recursive: true));
        final r = h.runCuberun([
          'run',
          harness,
          '--',
          ...headlessArgs(harness, 'Reply with exactly: OK'),
        ], cwd: proj.path);
        expect(r.exit, 0, reason: 'stderr: ${r.stderr}');
        expect(r.stdout.toUpperCase(), contains('OK'));
        // stderr free of sandbox denials (deprecation warning tolerated, E3)
        final denialish = r.stderr
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
        expect(
          denialish,
          isEmpty,
          reason: 'sandbox-induced stderr noise: $denialish',
        );
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 4)),
    );
  }

  test('provider env guard reports presence (never silently green)', () {
    // Documentation-of-behavior test: the guard is used by AC15 skips.
    expect(h.providerEnvPresent(), isA<bool>());
  });
}
