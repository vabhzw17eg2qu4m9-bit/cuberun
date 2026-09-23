import 'dart:convert';

import 'package:cube_sandbox/src/launcher.dart';
import 'package:test/test.dart';

/// Issue #81 C1(c)/(h) — the spawn is OBSERVABLE: `CUBE_SANDBOX_SPAWN_LOG`
/// makes `launchConfined` append one JSON line per spawn, so launch-path
/// equivalence (IT-1) and field instrumentation never rely on source
/// shape. The log records exactly what the child sees: backend, argv
/// (profile + verbatim tail), mode, wait.
void main() {
  test('one parseable JSON line: backend, argv, mode, wait', () {
    final line = spawnLogLine(
      backend: 'sandbox-exec',
      profilePath: '/p/.cube-sandbox/cache/harness-3f4f37c2ce.sb',
      command: ['pi', '-e', 'extensions/pi-pi.ts', '--session', 'u-123'],
      wait: false,
    );
    expect(line, isNot(contains('\n')));
    final m = jsonDecode(line) as Map<String, dynamic>;
    expect(m['backend'], 'sandbox-exec');
    expect(m['mode'], 'inheritStdio');
    expect(m['wait'], isFalse);
    expect(m.keys.toSet(), {'backend', 'argv', 'mode', 'wait'});
  });

  test('argv is sandbox-exec-shaped: -f profile, then the verbatim tail', () {
    final line = spawnLogLine(
      backend: 'sandbox-exec',
      profilePath: '/p/harness-abc.sb',
      command: ['/bin/sh', 'probe.sh', '--session', 'u-123'],
      wait: true,
    );
    final m = jsonDecode(line) as Map<String, dynamic>;
    expect(m['argv'], [
      '-f',
      '/p/harness-abc.sb',
      '/bin/sh',
      'probe.sh',
      '--session',
      'u-123',
    ]);
    // The volatile per-launch tail rides the ARGV — never the profile
    // key (C2); the log proves the tail is forwarded verbatim (#43).
    expect((m['argv'] as List).last, 'u-123');
  });
}
