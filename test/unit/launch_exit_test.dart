import 'dart:io';

import 'package:cube_sandbox/src/launcher.dart';
import 'package:test/test.dart';

/// UT-1 (issue #53, migrated to the #113 shape API) — the spawnExit
/// launch exit is the SPAWN status: 0 once the confined child is running
/// (the child's own exit code is neither observed nor waited on), 126
/// fail-closed when the backend cannot spawn (ProcessException — nothing
/// ran unconfined). The `wait` shape keeps the blocking contract: child
/// code verbatim, signal n => 128+n (the `mapChildExit` mapping itself is
/// covered by exit_map_test.dart). The `exec` shape fails closed 126 when
/// execve cannot replace the image; its success path replaces THIS
/// process, so it is pinned by the pty E2E suite, never by a unit test.
/// Drives the real `launchConfined` through the backend seam — no
/// sandbox-exec needed, runs on any host.
void main() {
  late Directory tmp;
  var n = 0;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-launch-exit-ut-');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A fake backend executable with [body]; ignores the -f/profile args.
  String backend(String body) {
    final p = '${tmp.path}/backend-${n++}.sh';
    File(p).writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', p]);
    return p;
  }

  test(
    'spawn success exits 0 immediately — the child code is NOT ours',
    () async {
      final code = await launchConfined(
        profilePath: '/dev/null',
        command: const [],
        backend: backend('sleep 5\nexit 7'),
        shape: LaunchShape.spawnExit,
      );
      expect(code, 0, reason: 'exit = spawn status, not the child code (7)');
    },
  );

  test('backend ProcessException fails closed: 126 + diagnostic', () async {
    final diag = <String>[];
    final code = await launchConfined(
      profilePath: '/dev/null',
      command: const ['true'],
      backend: '${tmp.path}/no-such-backend',
      shape: LaunchShape.spawnExit,
      onFailClosed: diag.add,
    );
    expect(code, 126);
    expect(diag.single, contains('fail closed'));
  });

  test(
    'exec shape: unusable backend fails closed 126, nothing spawned',
    () async {
      // #113 — the exec path never Process.start()s: execve either replaces
      // this image (E2E-pinned, impossible to unit-test in-process) or
      // fails with the image untouched. An ENOENT backend exercises the
      // failure arm: 126, the exec-specific diagnostic, and no child ever
      // existed — nothing ran unconfined.
      final diag = <String>[];
      final code = await launchConfined(
        profilePath: '/dev/null',
        command: const ['true'],
        backend: '${tmp.path}/no-such-backend',
        shape: LaunchShape.exec,
        onFailClosed: diag.add,
      );
      expect(code, 126);
      expect(diag.single, contains('exec failed'));
      expect(diag.single, contains('fail closed'));
    },
  );

  test('--wait blocks and forwards the child code verbatim', () async {
    final code = await launchConfined(
      profilePath: '/dev/null',
      command: const [],
      backend: backend('exit 7'),
      shape: LaunchShape.wait,
    );
    expect(code, 7);
  });

  test('--wait maps signal deaths to 128+n (SIGKILL => 137)', () async {
    final code = await launchConfined(
      profilePath: '/dev/null',
      command: const [],
      backend: backend('kill -9 \$\$'),
      shape: LaunchShape.wait,
    );
    expect(code, 137);
  });

  // --- issue #81: spawn observability + launcher-not-its-own-signal.

  test('spawnLogPath receives one JSON record per launch', () async {
    final log = '${tmp.path}/spawn.log';
    final code = await launchConfined(
      profilePath: '/p/harness-abc.sb',
      command: const ['pi', '--session', 'u-1'],
      backend: backend('exit 0'),
      shape: LaunchShape.wait,
      spawnLogPath: log,
    );
    expect(code, 0);
    final lines = File(log).readAsLinesSync();
    expect(lines, hasLength(1));
    expect(lines.single, contains('"wait":true'));
    expect(lines.single, contains('/p/harness-abc.sb'));
    expect(lines.single, contains('u-1'));
  });

  test('unwaited spawn records wait:false in the log', () async {
    final log = '${tmp.path}/spawn.log';
    await launchConfined(
      profilePath: '/dev/null',
      command: const [],
      backend: backend('exit 0'),
      shape: LaunchShape.spawnExit,
      spawnLogPath: log,
    );
    expect(File(log).readAsLinesSync().single, contains('"wait":false'));
  });

  test('a broken spawnLogPath never breaks the launch', () async {
    final code = await launchConfined(
      profilePath: '/dev/null',
      command: const [],
      backend: backend('exit 0'),
      shape: LaunchShape.wait,
      spawnLogPath: '${tmp.path}/no-such-dir/log.jsonl',
    );
    expect(code, 0, reason: 'diagnostics are best-effort');
  });
}
