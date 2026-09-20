/// Launcher: `sandbox-exec -f <profile> <command…>` with faithful exit
/// semantics — child killed by signal n => launcher exits 128 + n (POSIX,
/// AC7/E6); codes pass through; spawn failures fail closed (126).
library;

import 'dart:io' as io;

/// Maps a dart child exit code to the launcher's POSIX exit: dart reports
/// signal deaths as NEGATIVE exit codes; `-9` (SIGKILL) becomes 137.
int mapChildExit(int exitCode) => exitCode < 0 ? 128 - exitCode : exitCode;

/// Spawns the confined child with inherited stdio; NEVER throws — returns
/// the exit code cuberun itself should exit with (126 on spawn failure).
Future<int> launchConfined({
  required String profilePath,
  required List<String> command,
  void Function(String line)? onFailClosed,
}) async {
  final List<int> code;
  try {
    final proc = await io.Process.start('sandbox-exec', [
      '-f',
      profilePath,
      ...command,
    ], mode: io.ProcessStartMode.inheritStdio);
    code = [await proc.exitCode];
  } on io.ProcessException catch (e) {
    onFailClosed?.call(
      'kernel backend unavailable: ${e.message} (fail closed; nothing ran)',
    );
    return 126;
  }
  return mapChildExit(code.first);
}
