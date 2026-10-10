/// Launcher: `sandbox-exec -f <profile> <command…>` in one of three
/// shapes (issue #113): `exec` — cube-sandbox replaces its own image via
/// execvp(2), so ZERO launcher processes stay resident: the harness IS
/// the shell's foreground job and its exit code / signal deaths surface
/// natively; `spawnExit` — #53 headless spawn-and-exit: exit 0 once the
/// confined child is running (the harness outlives us; the kernel keeps
/// the boundary); `wait` — #81 blocking parent that holds the foreground
/// and forwards the child exit: code verbatim, signal n => 128 + n
/// (POSIX). Every shape is fail-closed 126 when nothing ran. [launchShape]
/// is the policy; [spawnLogLine] the observability seam
/// (`CUBE_SANDBOX_SPAWN_LOG`).
library;

import 'dart:convert' show jsonEncode;
import 'dart:ffi' as ffi;
import 'dart:io' as io;

import 'package:ffi/ffi.dart';

/// Maps a dart child exit code to the launcher's POSIX exit: dart reports
/// signal deaths as NEGATIVE exit codes; `-9` (SIGKILL) becomes 137.
int mapChildExit(int exitCode) => exitCode < 0 ? 128 - exitCode : exitCode;

/// Issue #113 — how [launchConfined] relates to the confined child:
/// `exec` replaces the launcher image (no resident parent at all),
/// `spawnExit` returns at spawn (#53), `wait` blocks for the child (#81).
enum LaunchShape { exec, spawnExit, wait }

/// Issue #113 launch-shape policy. A caller with a terminal on stdin gets
/// the exec shape: cube-sandbox execs into the backend, so the harness is
/// the shell's own foreground job — its exit code and signal deaths
/// surface natively, and there is no resident launcher to orphan it (the
/// #81 raw-mode EIO hazard is unconstructible). Headless callers keep #53
/// spawn-and-exit byte-identical. `--wait` forces the blocking parent
/// shape everywhere. `--spawn-exit` survives for CLI compatibility only:
/// exec already leaves nothing resident from a tty, and the headless
/// default IS spawn-and-exit — the flag can no longer change the shape.
LaunchShape launchShape({
  required bool waitFlag,
  required bool spawnExitFlag,
  required bool stdinHasTerminal,
}) {
  if (waitFlag) return LaunchShape.wait;
  return stdinHasTerminal ? LaunchShape.exec : LaunchShape.spawnExit;
}

/// Issue #81 C1(c)/(h) — one JSON line describing the spawn, exactly as
/// the child sees it. Appended to `$CUBE_SANDBOX_SPAWN_LOG` by
/// [launchConfined] so launch-path equivalence (IT-1) and field
/// instrumentation never rely on source shape. Pure and deterministic.
/// [wait] is true only for the blocking shape; exec and spawn-and-exit
/// both record false — argv is identical across ALL shapes (#113).
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

/// Runs the confined child with inherited stdio; NEVER throws. `exec`
/// replaces this image with the backend (execvp — PATH-searched like the
/// spawn shapes, #113) — the call only
/// returns (126) when the image could not be replaced: fail-closed,
/// nothing ran. `spawnExit` returns the SPAWN status: 0 on successful
/// spawn (the child's own exit is neither observed nor waited on), 126
/// when the spawn itself failed. `wait` blocks and returns the child's
/// mapped exit code instead, ignoring SIGINT so the harness's own signal
/// death (GOAL E6: 130) is what surfaces — never cube-sandbox's.
/// [backend] names the kernel backend executable (test seam, default
/// `sandbox-exec`); [spawnLogPath] optionally receives one JSON spawn
/// record per launch (issue #81, `CUBE_SANDBOX_SPAWN_LOG`).
Future<int> launchConfined({
  required String profilePath,
  required List<String> command,
  required LaunchShape shape,
  String backend = 'sandbox-exec',
  void Function(String line)? onFailClosed,
  String? spawnLogPath,
}) async {
  if (shape == LaunchShape.exec) {
    // Dart buffers stderr — the banner must be OUT before this process
    // becomes sandbox-exec, or it dies with the replaced image (#113).
    await io.stderr.flush();
    _logSpawn(spawnLogPath, backend, profilePath, command, false);
    final errno = _execBackend(backend, profilePath, command);
    // execvp returned => the image was never replaced; nothing ran.
    onFailClosed?.call('exec failed: $errno (fail closed; nothing ran)');
    return 126;
  }
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
  final wait = shape == LaunchShape.wait;
  _logSpawn(spawnLogPath, backend, profilePath, command, wait);
  if (!wait) return 0; // spawn status only — the harness is on its own
  // GOAL E6: on a real terminal the SIGINT goes to the whole foreground
  // pgrp — us included. The launcher must NOT die of its own signal: it
  // ignores SIGINT, lets the harness handle it, and maps the harness's
  // death (130 for SIGINT) as the exit. Watching suppresses the default
  // terminate; the child still gets the signal untouched. (The exec
  // shape needs none of this: there is no launcher left to kill.)
  final sigint = io.ProcessSignal.sigint.watch().listen((_) {});
  try {
    return mapChildExit(await proc.exitCode);
  } finally {
    await sigint.cancel();
  }
}

/// execvp(2) the backend in THIS process (issue #113):
/// `sandbox-exec -f <profile> <command…>`. execvp PATH-searches the bare
/// backend name exactly like the spawn shapes' `Process.start`, and
/// passes the caller's own environ untouched (POSIX: execvp == execve
/// with environ). Returns the errno if — and only if — the exec failed;
/// on success it NEVER returns.
int _execBackend(String backend, String profilePath, List<String> command) {
  final dylib = ffi.DynamicLibrary.process();
  final execvp = dylib
      .lookupFunction<
        ffi.Int32 Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Pointer<Utf8>>),
        int Function(ffi.Pointer<Utf8>, ffi.Pointer<ffi.Pointer<Utf8>>)
      >('execvp');

  // argv[0] is the image's own name by exec convention; the test seam
  // may point [backend] at an arbitrary path while argv[0] stays the
  // production name — mirroring Process.start's argv, minus the path.
  final args = ['sandbox-exec', '-f', profilePath, ...command];
  final argv = calloc<ffi.Pointer<Utf8>>(args.length + 1);
  final owned = <ffi.Pointer<Utf8>>[];
  for (var i = 0; i < args.length; i++) {
    final s = args[i].toNativeUtf8();
    owned.add(s);
    argv[i] = s;
  }
  argv[args.length] = ffi.nullptr;

  final exePath = backend.toNativeUtf8();
  execvp(exePath, argv);
  // Only a failed exec ever reaches this line (execvp returns -1; the
  // reason is in errno) — free what we built, then fail closed.
  final errno = _errno(dylib);
  malloc.free(exePath);
  for (final s in owned) {
    malloc.free(s);
  }
  calloc.free(argv);
  return errno;
}

/// macOS errno facility: `__error()` returns a pointer to the per-thread
/// errno (libc has no lookup-able `errno` symbol). -1 when the platform
/// offers no such symbol — the launch still fails closed, just without
/// the numeric detail.
int _errno(ffi.DynamicLibrary dylib) {
  try {
    final error = dylib
        .lookupFunction<
          ffi.Pointer<ffi.Int32> Function(),
          ffi.Pointer<ffi.Int32> Function()
        >('__error');
    return error().value;
  } on ArgumentError {
    return -1;
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
