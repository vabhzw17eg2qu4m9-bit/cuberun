/// Fail-closed backend preflight: missing/rejecting kernel backend means
/// the command does NOT run unconfined — exit 126 + diagnostic (AC5).
library;

import 'dart:convert' as convert;
import 'dart:io' as io;

/// Outcome of one command execution (launch failure distinguished from a
/// real exit code).
final class CommandOutcome {
  /// Creates an outcome; [exitCode] null means the launch itself failed.
  const CommandOutcome({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Child exit code, or null when the process could not be spawned.
  final int? exitCode;

  /// Captured stdout.
  final String stdout;

  /// Captured stderr.
  final String stderr;

  /// Whether the process never started.
  bool get launchFailed => exitCode == null;
}

/// Injectable command execution (tests fake the backend).
typedef CommandRunner = Future<CommandOutcome> Function(
  String exe,
  List<String> args,
);

/// dart:io-backed runner: spawns, captures both pipes, never inherits.
Future<CommandOutcome> processRunner(String exe, List<String> args) async {
  try {
    final proc = await io.Process.start(exe, args);
    final outFut = proc.stdout
        .transform(const convert.Utf8Decoder(allowMalformed: true))
        .join();
    final errFut = proc.stderr
        .transform(const convert.Utf8Decoder(allowMalformed: true))
        .join();
    final pipes = await Future.wait<String>([outFut, errFut]);
    final code = await proc.exitCode;
    return CommandOutcome(
      exitCode: code,
      stdout: pipes.first,
      stderr: pipes.last,
    );
  } catch (e) {
    return CommandOutcome(exitCode: null, stdout: '', stderr: '$e');
  }
}

/// Preflight result: [ok] false carries a printable [detail].
final class BackendCheck {
  /// Creates a check result.
  const BackendCheck({required this.ok, required this.detail});

  /// Whether the backend can confine.
  final bool ok;

  /// Human diagnostic (printed by the CLI on failure).
  final String detail;
}

/// Runs the fail-closed preflight: host platform must be macOS,
/// `sandbox-exec` must exist, and the backend must ACCEPT a trivial
/// profile (a rejecting/sabotaged backend fails closed too).
Future<BackendCheck> preflightBackend({
  CommandRunner? runner,
  String Function()? platform,
  String? Function(String name)? which,
}) async {
  runner ??= processRunner;
  platform ??= () => io.Platform.operatingSystem;
  which ??= _whichPath;

  final p = platform();
  if (p != 'macos') {
    return BackendCheck(ok: false, detail: 'not macOS ($p)');
  }
  final sandboxExec = which('sandbox-exec');
  if (sandboxExec == null) {
    return BackendCheck(ok: false, detail: 'sandbox-exec not found on PATH');
  }
  final probe = await runner(
    sandboxExec,
    ['-p', '(version 1)(allow default)', '/usr/bin/true'],
  );
  if (probe.launchFailed) {
    return BackendCheck(ok: false, detail: 'sandbox-exec probe could not run');
  }
  if (probe.exitCode != 0) {
    return BackendCheck(
      ok: false,
      detail: 'sandbox-exec probe exited ${probe.exitCode}: '
          '${probe.stderr.trim().split('\n').take(3).join(' | ')}',
    );
  }
  return BackendCheck(ok: true, detail: 'sandbox-exec probe ok');
}

/// Minimal `which`: first PATH entry holding an executable [name];
/// absolute [name]s are checked as-is.
String? _whichPath(String name) {
  if (name.contains('/')) {
    final f = io.File(name);
    return f.existsSync() && (f.statSync().mode & 0x49) != 0 ? name : null;
  }
  final path = io.Platform.environment['PATH'] ?? '';
  for (final dir in path.split(':')) {
    if (dir.trim().isEmpty) continue;
    final candidate = '$dir/$name';
    final f = io.File(candidate);
    if (f.existsSync() && (f.statSync().mode & 0x49) != 0) return candidate;
  }
  return null;
}
