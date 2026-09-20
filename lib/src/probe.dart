/// `cuberun probe`: confinement self-checks run FROM INSIDE the staged
/// profile — write-outside denied, project rw works, `$HOME` read+write+
/// listing denied outside grants, read grant read-only, write grant rw,
/// network open (AC6). The negative control (a sabotaged profile MUST
/// fail the probe) lives in the E2E suite.
library;

import 'dart:io' as io;

import 'preflight.dart';
import 'runtime.dart';
import 'sbpl.dart';
import 'stage.dart';

/// One probe check outcome.
final class ProbeCheck {
  /// Creates a check row.
  const ProbeCheck({required this.name, required this.ok, this.info = ''});

  /// Short check name.
  final String name;

  /// Passed / failed.
  final bool ok;

  /// Failure detail (empty when ok).
  final String info;
}

/// Full probe report.
final class ProbeReport {
  /// Creates a report.
  const ProbeReport({required this.checks});

  /// Every check, in execution order.
  final List<ProbeCheck> checks;

  /// True iff every check passed.
  bool get allPassed => checks.every((c) => c.ok);

  /// Count of failures.
  int get failed => checks.where((c) => !c.ok).length;
}

/// Runs one bash snippet inside `sandbox-exec -f [profilePath]`,
/// returning (exit code, stdout).
Future<({int code, String out})> _bashOut(
  CommandRunner runner,
  String profilePath,
  String script,
) async {
  final r = await runner(
    'sandbox-exec',
    ['-f', profilePath, '/bin/bash', '-c', script],
  );
  return (code: r.exitCode ?? 126, out: r.stdout);
}

/// Single-quotes [s] for a bash -c snippet.
String _q(String s) => "'${s.replaceAll("'", "'\"'\"'")}'";

/// Runs the probe battery against [profilePath] built from [runtime].
///
/// [home] is the real user home: the probe plants secrets OUTSIDE every
/// grant (from the unconfined launcher process) and asserts the kernel
/// denies the confined child access to them. [runner] injects execution
/// for tests.
Future<ProbeReport> probeHarness({
  required HarnessRuntime runtime,
  required String profilePath,
  required String home,
  CommandRunner? runner,
}) async {
  runner ??= processRunner;
  final checks = <ProbeCheck>[];
  void add(String name, bool ok, [String info = '']) =>
      checks.add(ProbeCheck(name: name, ok: ok, info: info));

  // 1) write outside writable roots must fail.
  final escapeFile = '$home/.cuberun-probe-escape';
  final esc = await _bashOut(runner, profilePath, 'echo x > ${_q(escapeFile)}');
  add(
    'write outside roots denied',
    esc.code != 0 && !io.File(escapeFile).existsSync(),
    'code=${esc.code}',
  );

  // 2) write+read inside project must succeed.
  final insideFile = '${runtime.projDir}/.cuberun-probe-inside';
  final inside = await _bashOut(
    runner,
    profilePath,
    'echo ok > ${_q(insideFile)} && cat ${_q(insideFile)}',
  );
  add(
    'write+read inside project works',
    inside.code == 0 && inside.out.trim() == 'ok',
    'code=${inside.code} out=${inside.out.trim()}',
  );

  // 3) $HOME outside every grant: read AND write denied.
  final secretDir = '$home/.cuberun-probe-secret';
  io.Directory(secretDir).createSync(recursive: true);
  io.File('$secretDir/flag').writeAsStringSync('secret\n');
  final rd = await _bashOut(
    runner,
    profilePath,
    'cat ${_q('$secretDir/flag')} 2>/dev/null; '
        'echo x > ${_q('$secretDir/w')} 2>/dev/null; echo done',
  );
  final secretLeaked = rd.out.contains('secret');
  final secretWritten = io.File('$secretDir/w').existsSync();
  add(
    r'$HOME outside roots denied (read AND write)',
    !secretLeaked && !secretWritten && rd.out.trim() == 'done',
    'out=${rd.out.trim()}',
  );

  // 3b) directory LISTING stays denied (metadata-only under deny roots).
  final lsRun = await _bashOut(
    runner,
    profilePath,
    'ls ${_q(home)} >/dev/null 2>&1; echo ls=\$?',
  );
  add(
    r'$HOME listing denied (metadata-only)',
    lsRun.out.trim() == 'ls=1' || lsRun.out.trim() == 'ls=2',
    'out=${lsRun.out.trim()}',
  );

  // 4) a read grant is READ-ONLY (probe variant re-emits + re-stages).
  final roRuntime = runtime.withGrants(read: [secretDir]);
  final roProfile = emitProfile(roRuntime);
  final roPath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: roProfile.text,
    key10: roProfile.key10,
  );
  final roRun = await _bashOut(
    runner,
    roPath,
    'cat ${_q('$secretDir/flag')}; touch ${_q('$secretDir/w2')} 2>/dev/null; true',
  );
  add(
    'read grant is read-only',
    roRun.out.trim() == 'secret' && !io.File('$secretDir/w2').existsSync(),
    'out=${roRun.out.trim()}',
  );

  // 5) a write grant is read+write.
  final rwDir = '$home/.cuberun-probe-rw';
  io.Directory(rwDir).createSync(recursive: true);
  final rwRuntime = runtime.withGrants(write: [rwDir]);
  final rwProfile = emitProfile(rwRuntime);
  final rwPath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: rwProfile.text,
    key10: rwProfile.key10,
  );
  final rwRun = await _bashOut(
    runner,
    rwPath,
    'echo rw-ok > ${_q('$rwDir/f')} && cat ${_q('$rwDir/f')}',
  );
  add(
    'write grant is read+write',
    rwRun.code == 0 &&
        io.File('$rwDir/f').existsSync() &&
        io.File('$rwDir/f').readAsStringSync().trim() == 'rw-ok',
    'code=${rwRun.code}',
  );

  // 6) network open (Layer-0 boundary is the FS; cubes deny net inside).
  var hits = 0;
  final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
  final port = server.port;
  server.listen((req) {
    hits++;
    req.response
      ..statusCode = 200
      ..write('pong')
      ..close();
  });
  final net = await _bashOut(
    runner,
    profilePath,
    'curl -s http://127.0.0.1:$port/ping',
  );
  add(
    'network open (allow network*)',
    net.code == 0 && hits >= 1 && net.out.trim() == 'pong',
    'code=${net.code} hits=$hits out=${net.out.trim()}',
  );
  await server.close();

  // cleanup probe litter (launcher runs unconfined; only children are
  // inside the kernel boundary).
  io.Directory(secretDir).deleteSync(recursive: true);
  io.Directory(rwDir).deleteSync(recursive: true);
  for (final p in [roPath, rwPath]) {
    final f = io.File(p);
    if (f.existsSync()) f.deleteSync();
  }

  return ProbeReport(checks: checks);
}
