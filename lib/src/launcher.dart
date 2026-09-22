/// Launcher: `sandbox-exec -f <profile> <command…>` with spawn-and-exit
/// semantics (issue #53): by default the exit is the SPAWN status — 0
/// once the confined child is running (the harness outlives us; the
/// kernel keeps the boundary), 126 fail-closed when nothing ran.
/// `wait: true` (`--wait`) preserves the blocking contract verbatim:
/// child code passes through, signal n => 128 + n (POSIX).
library;

import 'dart:io' as io;

/// Maps a dart child exit code to the launcher's POSIX exit: dart reports
/// signal deaths as NEGATIVE exit codes; `-9` (SIGKILL) becomes 137.
int mapChildExit(int exitCode) => exitCode < 0 ? 128 - exitCode : exitCode;

/// Spawns the confined child with inherited stdio; NEVER throws. Default
/// mode returns the SPAWN status: 0 on successful spawn (the child's own
/// exit is neither observed nor waited on), 126 when the spawn itself
/// failed — fail-closed, nothing ran unconfined. With [wait], blocks and
/// returns the child's mapped exit code instead. [backend] names the
/// kernel backend executable (test seam, default `sandbox-exec`).
Future<int> launchConfined({
  required String profilePath,
  required List<String> command,
  bool wait = false,
  String backend = 'sandbox-exec',
  void Function(String line)? onFailClosed,
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
  if (!wait) return 0; // spawn status only — the harness is on its own
  return mapChildExit(await proc.exitCode);
}
