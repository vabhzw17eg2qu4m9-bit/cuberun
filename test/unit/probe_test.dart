/// probeHarness unit tests: the injected runner fakes the confined child
/// (canned exit/stdout per check, real side effects where the probe checks
/// the filesystem), so every check's pass/fail logic is covered without a
/// host backend. The negative control (sabotaged profile MUST fail) is
/// mirrored here: a leaky fake makes the corresponding check trip.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'package:cuberun/src/preflight.dart';
import 'package:cuberun/src/probe.dart';
import 'package:cuberun/src/runtime.dart';
import 'package:cuberun/src/stage.dart';
import 'package:test/test.dart';

/// Marker substrings identifying each probe script, in execution order.
const _markers = [
  '.cuberun-probe-escape',
  '.cuberun-probe-inside',
  '.cuberun-probe-secret',
  'echo ls=',
  'touch',
  'rw-ok',
  '/ping',
];

const _checkNames = [
  'write outside roots denied',
  'write+read inside project works',
  r'$HOME outside roots denied (read AND write)',
  r'$HOME listing denied (metadata-only)',
  'read grant is read-only',
  'write grant is read+write',
  'network open (allow network*)',
];

/// The happy-path child: every confined operation behaves as a correct
/// kernel-enforced sandbox would (denied outside grants, allowed inside).
Future<CommandOutcome> _canned(String script) async {
  if (script.contains('.cuberun-probe-escape')) {
    return const CommandOutcome(
      exitCode: 1,
      stdout: '',
      stderr: 'operation not permitted',
    );
  }
  if (script.contains('.cuberun-probe-inside')) {
    return const CommandOutcome(exitCode: 0, stdout: 'ok\n', stderr: '');
  }
  if (script.contains('touch')) {
    // Check 4 (read grant): read succeeds, the touch is a no-op.
    return const CommandOutcome(exitCode: 0, stdout: 'secret\n', stderr: '');
  }
  if (script.contains('.cuberun-probe-secret')) {
    // Check 3: flag unread, w unwritten, only the trailing echo survives.
    return const CommandOutcome(exitCode: 0, stdout: 'done\n', stderr: '');
  }
  if (script.contains('echo ls=')) {
    return const CommandOutcome(exitCode: 0, stdout: 'ls=1\n', stderr: '');
  }
  if (script.contains('rw-ok')) {
    // Check 5: emulate the child really writing inside the granted dir.
    final path = RegExp(
      r"echo rw-ok > '([^']+)'",
    ).firstMatch(script)!.group(1)!;
    io.File(path).writeAsStringSync('rw-ok\n');
    return const CommandOutcome(exitCode: 0, stdout: '', stderr: '');
  }
  if (script.contains('/ping')) {
    // Check 6: emulate the child really reaching the loopback server.
    final url = RegExp(r'http://\S+').firstMatch(script)!;
    final client = io.HttpClient();
    final res = await (await client.getUrl(Uri.parse(url.group(0)!))).close();
    final body = await res.transform(utf8.decoder).join();
    client.close();
    return CommandOutcome(exitCode: 0, stdout: body, stderr: '');
  }
  fail('unexpected probe script: $script');
}

void main() {
  late io.Directory root;
  late String proj;
  late String home;

  setUp(() async {
    root = await io.Directory.systemTemp.createTemp('cuberun-probe-ut-');
    proj = '${root.path}/proj';
    home = '${root.path}/home';
    io.Directory(proj).createSync(recursive: true);
    io.Directory(home).createSync(recursive: true);
  });
  tearDown(() => root.delete(recursive: true));

  Future<ProbeReport> run(FutureOr<CommandOutcome> Function(String) handler) {
    final rt = HarnessRuntime(
      projDir: proj,
      agentRoot: '$home/.agent',
      tmp: root.path,
    );
    return probeHarness(
      runtime: rt,
      profilePath: stageProfile(
        cacheDir: projectCacheDir(proj),
        text: 'test-profile\n',
        key10: 'probeut001',
      ),
      home: home,
      runner: (exe, args) async => handler(args.last),
    );
  }

  test('all seven checks pass and run in order', () async {
    final ran = <String>[];
    final report = await run((script) async {
      ran.add(script);
      return _canned(script);
    });
    expect(report.allPassed, isTrue);
    expect(report.failed, 0);
    expect(ran.length, 7);
    for (final marker in _markers) {
      expect(
        ran.any((s) => s.contains(marker)),
        isTrue,
        reason: 'marker $marker never ran',
      );
    }
    expect(report.checks.map((c) => c.name), _checkNames);
    expect(report.checks.map((c) => c.ok), everyElement(isTrue));
  });

  test('escape write permitted => write-outside check fails only', () async {
    final report = await run(
      (script) => script.contains('.cuberun-probe-escape')
          ? const CommandOutcome(exitCode: 0, stdout: '', stderr: '')
          : _canned(script),
    );
    expect(report.allPassed, isFalse);
    expect(report.failed, 1);
    final bad = report.checks.singleWhere((c) => !c.ok);
    expect(bad.name, 'write outside roots denied');
    expect(bad.info, 'code=0');
  });

  test('negative control: leaky HOME trips the read AND write check', () async {
    final report = await run((script) async {
      if (script.contains('.cuberun-probe-secret') &&
          !script.contains('touch')) {
        // Simulate a sabotaged profile: the child reads the flag AND
        // really writes through the denied root.
        final dir = RegExp(r"cat '([^']+)/flag'").firstMatch(script)!.group(1)!;
        io.File('$dir/w').writeAsStringSync('x\n');
        return const CommandOutcome(
          exitCode: 0,
          stdout: 'secret\ndone\n',
          stderr: '',
        );
      }
      return _canned(script);
    });
    expect(report.allPassed, isFalse);
    final bad = report.checks.singleWhere(
      (c) => !c.ok && c.name.contains('HOME outside roots'),
    );
    expect(bad.info, 'out=secret\ndone');
  });

  test('writable read grant => read-grant check fails only', () async {
    final report = await run((script) async {
      if (script.contains('touch')) {
        // Simulate the re-staged profile allowing writes to the read grant.
        final path = RegExp(r"touch '([^']+)'").firstMatch(script)!.group(1)!;
        io.File(path).writeAsStringSync('x\n');
        return const CommandOutcome(
          exitCode: 0,
          stdout: 'secret\n',
          stderr: '',
        );
      }
      return _canned(script);
    });
    expect(report.failed, 1);
    expect(
      report.checks.singleWhere((c) => !c.ok).name,
      'read grant is read-only',
    );
  });

  test('network blackholed => network check fails (no real hit)', () async {
    final report = await run((script) async {
      if (script.contains('/ping')) {
        return const CommandOutcome(
          exitCode: 7,
          stdout: '',
          stderr: 'connection refused',
        );
      }
      return _canned(script);
    });
    expect(report.failed, 1);
    final bad = report.checks.singleWhere((c) => !c.ok);
    expect(bad.name, 'network open (allow network*)');
    expect(bad.info, contains('hits=0'));
  });
}
