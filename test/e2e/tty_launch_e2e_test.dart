@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issues #113 + #81 — interactive TUI terminal control under
/// cube-sandbox launch, on the exec contract.
///
/// #113 (exec default): from a tty cube-sandbox REPLACES ITSELF with the
/// confined harness via execve — measured mid-flight: the test's direct
/// child pid IS the probe's pid (cube → sandbox-exec → harness, one
/// pid), its image is no longer the launcher, and NO cube-sandbox
/// process remains resident. AC1 (proxy): a raw-mode probe (`stty raw
/// -echo`) survives the confined launch on a real pty — cold, cache-hit,
/// and after-edit.
/// AC2/IT-1: IDENTICAL arguments produce byte-identical spawn records
/// (`CUBE_SANDBOX_SPAWN_LOG`) on the fresh-build and cache-hit paths —
/// inheritStdio, no detach. Records for differing argv differ in the
/// verbatim tail BY DESIGN (#43); key equality is asserted separately.
/// AC3/IT-3: volatile per-launch argv (--session uuids) stages nothing
/// new and prints no warning; an emit-identical edit re-ties provenance
/// loudly (#70); a real emit-input change rebuilds under a new key.
/// E2: --spawn-exit from a tty is exec like the default — it can no
/// longer leave a resident launcher, so the #81 orphan/HUP hazard is
/// unconstructible; the record keeps wait:false.
/// E6: SIGINT reaches the foreground pgrp natively through the exec'd
/// image (130 via the shell), and `--wait` keeps the #81 blocking
/// watcher (the launcher never dies of its own SIGINT).
///
/// Platform facts this battery is built on (pinned, never silent):
/// - ps UNDER the profile is not reliable on newer macOS (E2E-7
///   precedent) — the probe publishes its own pid, and pgid/tpgid are
///   measured mid-flight from the UNCONFINED test process.
/// - script(1) exits at its direct child's death — under exec that IS
///   the harness, so a pty launch lives exactly as long as the probe.
/// - Wrapper exit status is intentionally NOT asserted — script(1)
///   propagation is not part of this contract; behavioral truth comes
///   from probe output, spawn records, staging state, and external ps.
///
/// Runs the compiled binary against the real sandbox-exec backend; every
/// pty test needs a working kernel AND a working script(1), so guards
/// skip loudly when the host lacks one (agent dev cubes deny
/// openpty/sandbox_apply).
void main() {
  final String? skipKernel = h.nestedSandboxDeniedReason();

  /// script(1) needs openpty AND an existing command to run — /bin/true
  /// does not exist on macOS, /usr/bin/true does (wrong path = silent
  /// nonzero = everything skipped, never silent here).
  String? ptyDeniedReason() {
    final r = Process.runSync('/usr/bin/script', [
      '-q',
      '/dev/null',
      '/usr/bin/true',
    ]);
    if (r.exitCode != 0) {
      return 'pty probe failed (script openpty or missing command): '
          'exit ${r.exitCode} stderr="${(r.stderr as String).trim()}" '
          'stdout="${(r.stdout as String).trim()}"';
    }
    return null;
  }

  final skipPty = ptyDeniedReason();

  /// Needs the kernel AND a pty (the tty-wait default only engages on a
  /// terminal stdin).
  void kernelPtyTest(
    String name,
    dynamic Function() body, {
    Timeout? timeout,
  }) => test(name, body, skip: skipKernel ?? skipPty, timeout: timeout);

  /// Kernel-only (headless): signals and pgrp isolation, no pty needed.
  void kernelTest(String name, dynamic Function() body, {Timeout? timeout}) =>
      test(name, body, skip: skipKernel, timeout: timeout);

  late Directory tmp;
  late Directory home;
  late String proj;
  late String probeSh;

  String writeScript(String name, String body) {
    final p = '$proj/$name.sh';
    File(p).writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', p]);
    return p;
  }

  void writeManifest(
    String name, {
    String extraWrite = '',
    String description = '',
  }) => File('$proj/.cube-sandbox/$name.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: $name${description.isEmpty ? '' : '\n  description: $description'}
spec:
  command:
    - /bin/sh
    - $probeSh
  agentRoot: $proj$extraWrite
''');

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-tty-');
    home = Directory.systemTemp.createTempSync('cube-sandbox-tty-home-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));
    proj = '${tmp.path}/proj';
    Directory('$proj/.cube-sandbox').createSync(recursive: true);
    // Raw-mode probe: the exact syscall class the reporter's pi dies on
    // (tcsetattr), then publishes its pid and holds the foreground for
    // HOLD seconds so the test can measure pgid/tpgid mid-flight from
    // OUTSIDE the sandbox (ps under the profile is unreliable — E2E-7).
    probeSh = writeScript('probe', '''
if stty raw -echo 2>/dev/null; then
  echo RAW-OK
else
  echo RAW-FAIL
fi
printf '%s\\n' "\$\$" > "\$PUB"
sleep "\$HOLD"
''');
  });

  Map<String, String> env([Map<String, String>? extra]) => {
    'HOME': home.path,
    ...?extra,
  };

  /// One integer from ps, mid-flight, measured from the UNCONFINED test
  /// process (ps under the profile is unreliable — E2E-7 precedent).
  int psInt(String expr) {
    final r = Process.runSync('/bin/sh', ['-c', expr]);
    final t = (r.stdout as String).trim();
    expect(
      t,
      isNotEmpty,
      reason: 'ps produced no output for "$expr" (exit ${r.exitCode})',
    );
    return int.parse(t);
  }

  final launcherName = h.ensureBinary().split('/').last;

  /// #113 exec contract, measured mid-flight from OUTSIDE the sandbox:
  /// the script child that was cube-sandbox now carries the PROBE's pid
  /// (cube execed into sandbox-exec which execed into the harness — one
  /// pid, never respawned), the image is no longer the launcher, and no
  /// cube-sandbox process is resident anywhere.
  void expectExecSwap(Process script, String probePid) {
    final launcherPid = psInt('pgrep -P ${script.pid}');
    expect(
      launcherPid,
      int.parse(probePid),
      reason:
          '#113: the probe pid IS the former launcher pid — the image '
          'was replaced in place, not respawned',
    );
    final r = Process.runSync('/bin/sh', [
      '-c',
      'ps -o ucomm= -p $launcherPid',
    ]);
    final ucomm = (r.stdout as String).trim();
    expect(
      ucomm,
      isNot(launcherName),
      reason: '#113: the launcher image is gone (this pid now runs: $ucomm)',
    );
    final resident = Process.runSync('/usr/bin/pgrep', ['-x', launcherName]);
    expect(
      resident.exitCode,
      1,
      reason: 'zero resident launcher (#113); found: ${resident.stdout}',
    );
  }

  /// Launches the compiled binary under script(1) WITHOUT waiting for
  /// completion: stdin is a pty, so the #113 exec default engages — the
  /// launcher image is replaced and the probe (its pid now) sleeps.
  Future<Process> spawnPty(
    List<String> args, {
    Map<String, String>? extraEnv,
  }) => Process.start(
    '/usr/bin/script',
    ['-q', '/dev/null', h.ensureBinary(), 'launch', ...args],
    workingDirectory: proj,
    environment: env(extraEnv),
  );

  /// Waits for the probe to publish its pid, asserts the #113 exec swap
  /// mid-flight, measures pgid/tpgid from the unconfined test process,
  /// then collects the full launch output.
  Future<({String out, int pgid, int tpgid})> launchPty(
    List<String> args, {
    required String pubPath,
    Map<String, String>? extraEnv,
    String hold = '4',
  }) async {
    if (File(pubPath).existsSync()) File(pubPath).deleteSync();
    final p = await spawnPty(
      args,
      extraEnv: {...?extraEnv, 'PUB': pubPath, 'HOLD': hold},
    );
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    String? pid;
    while (pid == null && DateTime.now().isBefore(deadline)) {
      final f = File(pubPath);
      if (f.existsSync()) {
        final t = f.readAsStringSync().trim();
        if (t.isNotEmpty) pid = t;
      }
      if (pid == null) sleep(const Duration(milliseconds: 50));
    }
    expect(pid, isNotNull, reason: 'probe never published its pid to $pubPath');

    expectExecSwap(p, pid!);
    final pgid = psInt('ps -o pgid= -p $pid');
    final tpgid = psInt('ps -o tpgid= -p $pid');
    final out = await p.stdout.transform(utf8.decoder).join();
    await p.exitCode;
    return (out: out, pgid: pgid, tpgid: tpgid);
  }

  List<String> stagedProfiles() =>
      Directory('$proj/.cube-sandbox/cache')
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => RegExp(r'harness-[0-9a-f]{10}\.sb$').hasMatch(p))
          .toList()
        ..sort();

  void expectForeground(String out, {required int pgid, required int tpgid}) {
    expect(
      out,
      contains('RAW-OK'),
      reason: 'raw-mode probe must succeed — output:\n$out',
    );
    // IT-2: the child pgrp OWNS the tty foreground (pgid == tpgid),
    // measured mid-flight from outside — under #113 the harness IS the
    // shell's foreground job; nothing ever backgrounded it.
    expect(pgid, tpgid, reason: 'child pgrp must be foreground (IT-2)');
  }

  kernelPtyTest('E2E-1/AC1+AC2+AC3: raw-mode probe survives cold, cache-hit, '
      'argv-variance and emit-identical-edit launches', () async {
    final log = '$proj/spawn.jsonl';
    final pub = '$proj/probe-pid';
    writeManifest('tty1');

    // L1 — cold cache.
    final r1 = await launchPty(
      ['tty1', '--session', 'u-1'],
      pubPath: pub,
      extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
    );
    expectForeground(r1.out, pgid: r1.pgid, tpgid: r1.tpgid);
    expect(r1.out, isNot(contains('provenance refreshed')));
    expect(stagedProfiles(), hasLength(1));
    final records = File(log).readAsLinesSync();
    expect(records, hasLength(1));
    final j1 = jsonDecode(records[0]) as Map<String, dynamic>;
    expect(j1['backend'], 'sandbox-exec');
    expect(j1['mode'], 'inheritStdio');
    expect(
      j1['wait'],
      isFalse,
      reason: '#113: tty default is exec — not the blocking shape',
    );
    expect((j1['argv'] as List).last, 'u-1');

    // L2 — cache-hit, IDENTICAL arguments: AC2's record-equality pair.
    final r2 = await launchPty(
      ['tty1', '--session', 'u-1'],
      pubPath: pub,
      extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
    );
    expectForeground(r2.out, pgid: r2.pgid, tpgid: r2.tpgid);
    expect(r2.out, isNot(contains('provenance refreshed')));
    expect(stagedProfiles(), hasLength(1), reason: 'same key10, no rebuild');
    final records2 = File(log).readAsLinesSync();
    expect(records2, hasLength(2));
    expect(
      records2[1],
      records2[0],
      reason: 'AC2: fresh vs cache-hit spawn byte-identical',
    );

    // L3 — DIFFERENT volatile argv (C2-only): same key10, no new
    // staging, no warning. The RECORD differs in the verbatim tail by
    // design (#43) — only the KEY must not move.
    final r3 = await launchPty(
      ['tty1', '--session', 'u-2-sentinel-different-argv'],
      pubPath: pub,
      extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
    );
    expectForeground(r3.out, pgid: r3.pgid, tpgid: r3.tpgid);
    expect(r3.out, isNot(contains('provenance refreshed')));
    expect(stagedProfiles(), hasLength(1), reason: 'volatile argv: same key');
    final records3 = File(log).readAsLinesSync();
    final j3 = jsonDecode(records3[2]) as Map<String, dynamic>;
    expect((j3['argv'] as List).last, 'u-2-sentinel-different-argv');
    expect(j3['argv'], isNot(j1['argv']), reason: 'tail rides argv (#43)');
    expect(
      (j3['argv'] as List).take(2),
      (j1['argv'] as List).take(2),
      reason: 'same staged profile path — the key never moved',
    );

    // L4 — emit-identical edit (description only): SAME key10, loud
    // provenance re-tie (#70), spawn record back to byte-identical.
    writeManifest('tty1', description: 'edited');
    final r4 = await launchPty(
      ['tty1', '--session', 'u-1'],
      pubPath: pub,
      extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
    );
    expectForeground(r4.out, pgid: r4.pgid, tpgid: r4.tpgid);
    expect(r4.out, contains('provenance refreshed'), reason: '#70 loudness');
    expect(stagedProfiles(), hasLength(1), reason: 'emit-identical: same key');
    final records4 = File(log).readAsLinesSync();
    expect(records4, hasLength(4));
    expect(
      records4[3],
      records4[0],
      reason: 'same emit + same argv => same spawn record',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));

  kernelPtyTest(
    'E2E-3/AC3: a real emit-input change rebuilds under a NEW key and '
    'raw mode survives the rebuild path',
    () async {
      final log = '$proj/spawn.jsonl';
      final pub = '$proj/probe-pid';
      writeManifest('tty2');
      final r1 = await launchPty(
        const ['tty2'],
        pubPath: pub,
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expectForeground(r1.out, pgid: r1.pgid, tpgid: r1.tpgid);
      final key1 = RegExp(r'profile ([0-9a-f]{10})').firstMatch(r1.out)![1]!;
      expect(stagedProfiles(), hasLength(1));

      // Widen extraWrite — a pinned emit input (#69): lawful rebuild.
      writeManifest('tty2', extraWrite: '\n  extraWrite: [~/.codemie]');
      final r2 = await launchPty(
        const ['tty2'],
        pubPath: pub,
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expectForeground(r2.out, pgid: r2.pgid, tpgid: r2.tpgid);
      final key2 = RegExp(r'profile ([0-9a-f]{10})').firstMatch(r2.out)![1]!;
      expect(key2, isNot(key1), reason: 'semantic change must change the key');
      expect(stagedProfiles(), hasLength(2), reason: 'new key staged');

      // The spawn record differs ONLY in the staged profile path — the
      // spawn FLAGS never diverge between the rebuild and cache paths.
      final lines = File(log).readAsLinesSync();
      final a = jsonDecode(lines[0]) as Map<String, dynamic>;
      final b = jsonDecode(lines[1]) as Map<String, dynamic>;
      expect(b['backend'], a['backend']);
      expect(b['mode'], a['mode']);
      expect(b['wait'], a['wait']);
      final argvA = a['argv'] as List;
      final argvB = b['argv'] as List;
      expect(argvB[0], argvA[0]);
      expect(argvB[1], isNot(argvA[1]), reason: 'new key10 profile path');
      expect(argvB.sublist(2), argvA.sublist(2), reason: 'harness argv equal');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  kernelPtyTest(
    'E2/#113: --spawn-exit from a terminal is exec — image replaced, '
    'record wait:false, harness lives out its natural life',
    () async {
      // Under #113 the flag can no longer spawn-and-return from a tty:
      // exec leaves nothing resident, so there is nothing to hand back.
      // The launch therefore lasts exactly the harness lifetime
      // (launchPty joins after the probe's HOLD) and the mid-flight
      // assertions prove the image swap. The #81 orphan/HUP hazard this
      // flag used to carry is unconstructible. The record stays
      // wait:false — only --wait records true.
      final log = '$proj/spawn.jsonl';
      final pub = '$proj/probe-pid';
      writeManifest('tty3');
      final t0 = DateTime.now();
      final r = await launchPty(
        const ['--spawn-exit', 'tty3'],
        pubPath: pub,
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(
        DateTime.now().difference(t0),
        greaterThan(const Duration(seconds: 3)),
        reason:
            'under exec the launcher IS the harness — a pty launch lasts '
            'the probe lifetime (HOLD), no fast spawn-and-return',
      );
      expect(r.out, contains('under cube-sandbox'), reason: 'banner printed');
      expect(
        jsonDecode(File(log).readAsLinesSync().single)['wait'],
        isFalse,
        reason: 'wait:false marks every non-blocking shape (#113)',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  kernelTest(
    'E6/#113: exec default — SIGINT to the foreground pgrp surfaces the '
    'harness death (130) natively',
    () async {
      final perl = '/usr/bin/perl';
      if (!File(perl).existsSync()) {
        fail('/usr/bin/perl missing — cannot isolate a process group');
      }
      // Stale files from an earlier run would short-circuit the waits —
      // start clean (never silent if the probe never shows up).
      final ready = '$proj/int-ready';
      final trapped = '$proj/int-trapped';
      final pidf = '$proj/int-pid';
      for (final f in [ready, trapped, pidf]) {
        final f0 = File(f);
        if (f0.existsSync()) f0.deleteSync();
      }
      final intSh = writeScript(
        'int',
        "trap 'printf int > \"\$TRAPPED\"; exit 130' INT\n"
            'printf ready > "\$MARK"\n'
            'printf \'%s\\n\' "\$\$" > "\$PIDF"\n'
            'sleep 30\n',
      );
      File('$proj/.cube-sandbox/tty4.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: tty4
spec:
  command:
    - /bin/sh
    - $intSh
  agentRoot: $proj
''');
      // NO --wait: cube-sandbox execs away at once — there is no launcher
      // left to watch or map signals. setpgrp(0,0) puts the whole chain
      // (perl → cube → sandbox-exec → probe) in one group; an INT to it
      // is the real-terminal ^C shape. The wrapper sh stays OUTSIDE the
      // group (plain fork, no exec) so it survives to map the death the
      // way a login shell does: signal n => 128+n. Whatever the kernel
      // hands it — sandbox-exec killed by INT, or its trap-driven 130 —
      // the shell reports 130.
      final inner = [
        perl,
        '-e',
        'setpgrp(0, 0); exec @ARGV',
        '--',
        h.ensureBinary(),
        'launch',
        'tty4',
      ].map((a) => "'${a.replaceAll("'", r"'\''")}'").join(' ');
      final p = await Process.start(
        '/bin/sh',
        ['-c', inner],
        workingDirectory: proj,
        environment: env({'MARK': ready, 'TRAPPED': trapped, 'PIDF': pidf}),
      );
      // The probe publishes its own pid (the same self-reporting contract
      // as the pty probes — ps under the profile is unreliable, E2E-7);
      // its pgid IS the leader group: setpgrp(0,0) made the whole chain
      // one group, whatever the wrapper sh forked or execed on the way.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!File(pidf).existsSync() && DateTime.now().isBefore(deadline)) {
        sleep(const Duration(milliseconds: 50));
      }
      expect(File(pidf).existsSync(), isTrue, reason: 'harness started');
      final probePid = File(pidf).readAsStringSync().trim();
      expect(probePid, isNotEmpty, reason: 'probe pid published');
      final pgid = psInt('ps -o pgid= -p $probePid');
      final kill = Process.runSync('kill', ['-s', 'INT', '-$pgid']);
      expect(kill.exitCode, 0, reason: kill.stderr as String);
      expect(
        await p.exitCode,
        130,
        reason:
            '130 = the harness\'s SIGINT death surfaced NATIVELY through '
            'the exec chain (signal n => 128+n via the shell) — nothing '
            'intercepted or remapped it',
      );
      final tDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (!File(trapped).existsSync() &&
          DateTime.now().isBefore(tDeadline)) {
        sleep(const Duration(milliseconds: 50));
      }
      expect(
        File(trapped).existsSync(),
        isTrue,
        reason: 'SIGINT reached the probe INSIDE the exec\'d image',
      );
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  kernelTest(
    'E6/#81 (--wait shape): SIGINT to the waiting launcher surfaces the '
    'harness death (130)',
    () async {
      final perl = '/usr/bin/perl';
      if (!File(perl).existsSync()) {
        fail('/usr/bin/perl missing — cannot isolate a process group');
      }
      final ready = '$proj/int-ready';
      final intSh = writeScript(
        'int',
        "trap 'exit 130' INT\nprintf ready > \"\$MARK\"\nsleep 30\n",
      );
      File('$proj/.cube-sandbox/tty4.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: tty4
spec:
  command:
    - /bin/sh
    - $intSh
  agentRoot: $proj
''');
      // Cube-sandbox options precede the profile (#43): --wait BEFORE
      // tty4 — after the profile it would be the harness's argv.
      // setpgrp(0,0) puts launcher + confined harness in one group; an
      // INT to that group is the real-terminal ^C shape (both get it).
      final p = await Process.start(
        perl,
        [
          '-e',
          'setpgrp(0, 0); exec @ARGV',
          '--',
          h.ensureBinary(),
          'launch',
          '--wait',
          'tty4',
        ],
        workingDirectory: proj,
        environment: env({'MARK': ready}),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!File(ready).existsSync() && DateTime.now().isBefore(deadline)) {
        sleep(const Duration(milliseconds: 50));
      }
      expect(File(ready).existsSync(), isTrue, reason: 'harness started');
      final kill = Process.runSync('kill', ['-s', 'INT', '-${p.pid}']);
      expect(kill.exitCode, 0, reason: kill.stderr as String);
      expect(
        await p.exitCode,
        130,
        reason:
            'expected 130 = the harness\'s SIGINT death (trap or '
            'mapped signal) — the launcher must not die of its own '
            'SIGINT first',
      );
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('pty control: the probe detects raw mode on an unconfined pty', () {
    // Capture guard: proves stty+pty actually work where the kernel
    // tests run — a RAW-OK from the confined flow means something only
    // if the same probe succeeds unconfined.
    final r = Process.runSync('/usr/bin/script', [
      '-q',
      '/dev/null',
      '/bin/sh',
      '-c',
      'stty raw -echo && echo RAW-OK',
    ]);
    expect(
      (r.stdout as String),
      contains('RAW-OK'),
      reason: r.stderr as String,
    );
  }, skip: skipPty);
}
