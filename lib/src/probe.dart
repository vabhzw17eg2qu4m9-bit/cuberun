/// `cube-sandbox probe`: confinement self-checks run FROM INSIDE the staged
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
  final r = await runner('sandbox-exec', [
    '-f',
    profilePath,
    '/bin/bash',
    '-c',
    script,
  ]);
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

  // 1) write outside writable roots must fail.
  final escapeFile = '$home/.cube-sandbox-probe-escape';

  // 2) write+read inside project must succeed.
  final insideFile = '${runtime.projDir}/.cube-sandbox-probe-inside';

  // 3) $HOME outside every grant: plant secrets OUTSIDE every grant (the
  // launcher runs unconfined; the confined child must be denied).
  final secretDir = '$home/.cube-sandbox-probe-secret';
  io.Directory(secretDir).createSync(recursive: true);
  io.File('$secretDir/flag').writeAsStringSync('secret\n');

  // 4) a read grant is READ-ONLY (probe variant re-emits + re-stages).
  final roProfile = emitProfile(runtime.withGrants(read: [secretDir]));
  final roPath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: roProfile.text,
    key10: roProfile.key10,
  );

  // 5) a write grant is read+write.
  final rwDir = '$home/.cube-sandbox-probe-rw';
  io.Directory(rwDir).createSync(recursive: true);
  final rwProfile = emitProfile(runtime.withGrants(write: [rwDir]));
  final rwPath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: rwProfile.text,
    key10: rwProfile.key10,
  );

  final checks = <ProbeCheck>[
    await _checkWriteOutsideDenied(runner, profilePath, escapeFile),
    await _checkInsideProject(runner, profilePath, insideFile),
    await _checkHomeDenied(runner, profilePath, secretDir),
    await _checkHomeListing(runner, profilePath, home),
    await _checkReadGrant(runner, roPath, secretDir),
    await _checkWriteGrant(runner, rwPath, rwDir),
    await _checkNetworkOpen(runner, profilePath),
  ];

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

/// Check 1: write outside writable roots must fail (escape file absent).
Future<ProbeCheck> _checkWriteOutsideDenied(
  CommandRunner runner,
  String profilePath,
  String escapeFile,
) async {
  final esc = await _bashOut(runner, profilePath, 'echo x > ${_q(escapeFile)}');
  return ProbeCheck(
    name: 'write outside roots denied',
    ok: esc.code != 0 && !io.File(escapeFile).existsSync(),
    info: 'code=${esc.code}',
  );
}

/// Check 2: write+read inside project must succeed.
Future<ProbeCheck> _checkInsideProject(
  CommandRunner runner,
  String profilePath,
  String insideFile,
) async {
  final inside = await _bashOut(
    runner,
    profilePath,
    'echo ok > ${_q(insideFile)} && cat ${_q(insideFile)}',
  );
  return ProbeCheck(
    name: 'write+read inside project works',
    ok: inside.code == 0 && inside.out.trim() == 'ok',
    info: 'code=${inside.code} out=${inside.out.trim()}',
  );
}

/// Check 3: `$HOME` outside every grant — read AND write denied.
Future<ProbeCheck> _checkHomeDenied(
  CommandRunner runner,
  String profilePath,
  String secretDir,
) async {
  final rd = await _bashOut(
    runner,
    profilePath,
    'cat ${_q('$secretDir/flag')} 2>/dev/null; '
    'echo x > ${_q('$secretDir/w')} 2>/dev/null; echo done',
  );
  final secretLeaked = rd.out.contains('secret');
  final secretWritten = io.File('$secretDir/w').existsSync();
  return ProbeCheck(
    name: r'$HOME outside roots denied (read AND write)',
    ok: !secretLeaked && !secretWritten && rd.out.trim() == 'done',
    info: 'out=${rd.out.trim()}',
  );
}

/// Check 3b: directory LISTING stays denied (metadata-only under deny roots).
Future<ProbeCheck> _checkHomeListing(
  CommandRunner runner,
  String profilePath,
  String home,
) async {
  final lsRun = await _bashOut(
    runner,
    profilePath,
    'ls ${_q(home)} >/dev/null 2>&1; echo ls=\$?',
  );
  return ProbeCheck(
    name: r'$HOME listing denied (metadata-only)',
    ok: lsRun.out.trim() == 'ls=1' || lsRun.out.trim() == 'ls=2',
    info: 'out=${lsRun.out.trim()}',
  );
}

/// Check 4: a read grant is READ-ONLY ([roPath] is the re-staged variant).
Future<ProbeCheck> _checkReadGrant(
  CommandRunner runner,
  String roPath,
  String secretDir,
) async {
  final roRun = await _bashOut(
    runner,
    roPath,
    'cat ${_q('$secretDir/flag')}; touch ${_q('$secretDir/w2')} 2>/dev/null; true',
  );
  return ProbeCheck(
    name: 'read grant is read-only',
    ok: roRun.out.trim() == 'secret' && !io.File('$secretDir/w2').existsSync(),
    info: 'out=${roRun.out.trim()}',
  );
}

/// Check 5: a write grant is read+write ([rwPath] is the re-staged variant).
Future<ProbeCheck> _checkWriteGrant(
  CommandRunner runner,
  String rwPath,
  String rwDir,
) async {
  final rwRun = await _bashOut(
    runner,
    rwPath,
    'echo rw-ok > ${_q('$rwDir/f')} && cat ${_q('$rwDir/f')}',
  );
  return ProbeCheck(
    name: 'write grant is read+write',
    ok:
        rwRun.code == 0 &&
        io.File('$rwDir/f').existsSync() &&
        io.File('$rwDir/f').readAsStringSync().trim() == 'rw-ok',
    info: 'code=${rwRun.code}',
  );
}

/// Check 6: network open (Layer-0 boundary is the FS; cubes deny net
/// inside). Owns the loopback HTTP server lifecycle.
Future<ProbeCheck> _checkNetworkOpen(
  CommandRunner runner,
  String profilePath,
) async {
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
  final check = ProbeCheck(
    name: 'network open (allow network*)',
    ok: net.code == 0 && hits >= 1 && net.out.trim() == 'pong',
    info: 'code=${net.code} hits=$hits out=${net.out.trim()}',
  );
  await server.close();
  return check;
}
