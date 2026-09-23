/// Launcher: `sandbox-exec -f <profile> <command…>` with spawn-and-exit
/// semantics (issue #53): for headless callers the exit is the SPAWN
/// status — 0 once the confined child is running (the harness outlives
/// us; the kernel keeps the boundary), 126 fail-closed when nothing
/// ran. `wait: true` (`--wait`, and by default any caller with a tty on
/// stdin — issue #81) holds the foreground for the child's lifetime and
/// passes the child exit through: code verbatim, signal n => 128 + n
/// (POSIX). [shouldWait] is the policy; [spawnLogLine] the observability
/// seam (`CUBE_SANDBOX_SPAWN_LOG`).
library;

import 'dart:convert' show jsonEncode;
import 'dart:io' as io;

/// Maps a dart child exit code to the launcher's POSIX exit: dart reports
/// signal deaths as NEGATIVE exit codes; `-9` (SIGKILL) becomes 137.
int mapChildExit(int exitCode) => exitCode < 0 ? 128 - exitCode : exitCode;

/// Issue #81 — launch-mode policy. A caller with a terminal on stdin is
/// running an interactive TUI: the launcher must HOLD the foreground for
/// the child's lifetime (wait), because exiting first hands the tty to
/// the shell's job control — the child pgrp ends up orphaned in the
/// background and raw-mode tcsetattr dies with EIO. Headless callers
/// keep #53 spawn-and-exit byte-identical. Explicit flags always win;
/// `--spawn-exit` forces the legacy shape from a terminal.
bool shouldWait({
  required bool waitFlag,
  required bool spawnExitFlag,
  required bool stdinHasTerminal,
}) {
  if (spawnExitFlag) return false;
  if (waitFlag) return true;
  return stdinHasTerminal;
}

/// Issue #81 C1(c)/(h) — one JSON line describing the spawn, exactly as
/// the child sees it. Appended to `$CUBE_SANDBOX_SPAWN_LOG` by
/// [launchConfined] so launch-path equivalence (IT-1) and field
/// instrumentation never rely on source shape. Pure and deterministic.
String spawnLogLine({
  required String backend,
  required String profilePath,
  required List<String> command,
  required bool wait,
}) => jsonEncode({
  'backend': backend,
  'argv': ['-f', profilePath, ...command],
  'mode': 'inheritStdio',
  'wait': wait,
});

/// Spawns the confined child with inherited stdio; NEVER throws. Default
/// mode returns the SPAWN status: 0 on successful spawn (the child's own
/// exit is neither observed nor waited on), 126 when the spawn itself
/// failed — fail-closed, nothing ran unconfined. With [wait], blocks and
/// returns the child's mapped exit code instead, ignoring SIGINT so the
/// harness's own signal death (GOAL E6: 130) is what surfaces — never
/// cube-sandbox's. [backend] names the kernel backend executable (test
/// seam, default `sandbox-exec`); [spawnLogPath] optionally receives one
/// JSON spawn record per launch (issue #81, `CUBE_SANDBOX_SPAWN_LOG`).
Future<int> launchConfined({
  required String profilePath,
  required List<String> command,
  bool wait = false,
  String backend = 'sandbox-exec',
  void Function(String line)? onFailClosed,
  String? spawnLogPath,
}) async {
  final io.Process proc;
  try {
    proc = await io.Process.start(backend, [
      '-f',
      profilePath,
      ...command,
    ], mode: io.ProcessStartMode.inheritStdio);
  } on io.ProcessException catch (e) {
    onFailClosed?.call(
      'kernel backend unavailable: ${e.message} (fail closed; nothing ran)',
    );
    return 126;
  }
  _logSpawn(spawnLogPath, backend, profilePath, command, wait);
  if (!wait) return 0; // spawn status only — the harness is on its own
  // GOAL E6: on a real terminal the SIGINT goes to the whole foreground
  // pgrp — us included. The launcher must NOT die of its own signal: it
  // ignores SIGINT, lets the harness handle it, and maps the harness's
  // death (130 for SIGINT) as the exit. Watching suppresses the default
  // terminate; the child still gets the signal untouched.
  final sigint = io.ProcessSignal.sigint.watch().listen((_) {});
  try {
    return mapChildExit(await proc.exitCode);
  } finally {
    await sigint.cancel();
  }
}

/// Best-effort spawn record (issue #81): appends one line to [path] when
/// non-empty. A broken log path must never break a launch.
void _logSpawn(
  String? path,
  String backend,
  String profilePath,
  List<String> cmd,
  bool wait,
) {
  if (path == null || path.isEmpty) return;
  try {
    io.File(path).writeAsStringSync(
      '${spawnLogLine(backend: backend, profilePath: profilePath, command: cmd, wait: wait)}\n',
      mode: io.FileMode.append,
      flush: true,
    );
  } on io.FileSystemException {
    // Field instrumentation is diagnostic only — never fail-closed here.
  }
}
