@Tags(['integration'])
library;

import 'package:cuberun/src/preflight.dart';
import 'package:test/test.dart';

/// AC5 — fail-closed preflight: non-macOS, missing binary, rejecting
/// backend — injected runner covers all three without a host; live check
/// on a real macOS host.
void main() {
  test('injected: non-macOS platform fails closed', () async {
    final check = await preflightBackend(
      platform: () => 'linux',
      runner: (exe, args) async =>
          const CommandOutcome(exitCode: 0, stdout: '', stderr: ''),
    );
    expect(check.ok, isFalse);
    expect(check.detail, contains('not macOS'));
  });

  test('injected: missing sandbox-exec fails closed', () async {
    final check = await preflightBackend(
      platform: () => 'macos',
      which: (_) => null,
      runner: (exe, args) async =>
          const CommandOutcome(exitCode: 0, stdout: '', stderr: ''),
    );
    expect(check.ok, isFalse);
    expect(check.detail, contains('not found'));
  });

  test('injected: rejecting backend fails closed with stderr detail', () async {
    final check = await preflightBackend(
      platform: () => 'macos',
      which: (_) => '/usr/bin/sandbox-exec',
      runner: (exe, args) async => const CommandOutcome(
        exitCode: 65,
        stdout: '',
        stderr: 'no version specified\nline 2\nline 3\nline 4',
      ),
    );
    expect(check.ok, isFalse);
    expect(check.detail, contains('exited 65'));
    expect(check.detail, contains('no version specified'));
  });

  test('injected: accepting backend passes', () async {
    final check = await preflightBackend(
      platform: () => 'macos',
      which: (_) => '/usr/bin/sandbox-exec',
      runner: (exe, args) async =>
          const CommandOutcome(exitCode: 0, stdout: '', stderr: ''),
    );
    expect(check.ok, isTrue);
  });

  test(
    'live: real host preflight (trivial profile applies even nested)',
    () async {
      final check = await preflightBackend();
      expect(check.ok, isTrue, reason: check.detail);
    },
    skip: false,
  );
}
