@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #81 — interactive TUI terminal control under cube-sandbox launch.
///
/// AC1 (proxy): a raw-mode probe (`stty raw -echo`) survives the confined
/// spawn on a real pty — cold, cache-hit, and after-edit.
/// AC2/IT-1: the spawn record (`CUBE_SANDBOX_SPAWN_LOG`) is byte-identical
/// across fresh-build and cache-hit launches — inheritStdio, no detach.
/// AC3/IT-3: volatile per-launch argv (--session uuids) stages nothing
/// new and prints no warning; an emit-identical edit re-ties provenance
/// loudly (#70); a real emit-input change rebuilds.
/// E2 (opt-out): --spawn-exit forces #53 spawn-and-exit from a tty.
/// E6: SIGINT to the waiting launcher surfaces the HARNESS's mapped death
/// (130), never the launcher's own.
///
/// Runs the compiled binary against the real sandbox-exec backend; every
/// test needs a pty AND a working kernel, so both guards skip loudly
/// when the host lacks one (agent dev cubes deny openpty/sandbox_apply).
void main() {
  final String? skipKernel = h.nestedSandboxDeniedReason();

  /// script(1) needs openpty — denied inside agent dev cubes.
  String? ptyDeniedReason() {
    final r = Process.runSync('/usr/bin/script', [
      '-q',
      '/dev/null',
      '/bin/true',
    ]);
    if (r.exitCode != 0) {
      return 'host denies pty allocation (script openpty): '
          '${(r.stderr as String).trim()}';
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

  void writeManifest(String name, {String extraWrite = ''}) =>
      File('$proj/.cube-sandbox/$name.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: $name
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
    // (tcsetattr), plus a pgrp/foreground fingerprint for IT-2.
    probeSh = writeScript('probe', '''
if stty raw -echo 2>/dev/null; then
  echo RAW-OK
else
  echo RAW-FAIL
fi
ps -o pgid=,tpgid= -p \$\$ | tr -s ' '
''');
  });

  Map<String, String> env([Map<String, String>? extra]) => {
    'HOME': home.path,
    ...?extra,
  };

  /// Launches the compiled binary under script(1): stdin is a pty, so
  /// the tty-wait default engages — the launcher holds the foreground
  /// and the probe output (plus banner/warnings) comes back merged.
  Future<(int exit, String out)> startPty(
    List<String> args, {
    Map<String, String>? extraEnv,
  }) async {
    final p = await Process.start(
      '/usr/bin/script',
      ['-q', '/dev/null', h.ensureBinary(), 'launch', ...args],
      workingDirectory: proj,
      environment: env(extraEnv),
    );
    final out = await p.stdout.transform(utf8.decoder).join();
    return (await p.exitCode, out);
  }

  List<String> stagedProfiles() =>
      Directory('$proj/.cube-sandbox/cache')
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => RegExp(r'harness-[0-9a-f]{10}\.sb$').hasMatch(p))
          .toList()
        ..sort();

  kernelPtyTest(
    'E2E-1/AC1+AC2+AC3: raw-mode probe survives cold, cache-hit and '
    'emit-identical-edit launches; spawn record byte-identical',
    () async {
      final log = '$proj/spawn.jsonl';
      writeManifest('tty1');

      // L1 — cold cache.
      final (exit1, out1) = await startPty(
        ['tty1', '--session', 'u-1'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(exit1, 0, reason: out1);
      expect(
        out1,
        contains('RAW-OK'),
        reason: 'cold launch must keep raw mode',
      );
      expect(out1, isNot(contains('provenance refreshed')));

      // IT-2: the child pgrp OWNS the tty foreground (pgid == tpgid) —
      // the launcher held it, nothing backgrounded the harness.
      final ps1 = RegExp(
        r'^\s*(\d+)\s+(\d+)\s*$',
        multiLine: true,
      ).firstMatch(out1)!;
      expect(
        ps1.group(1),
        ps1.group(2),
        reason: 'child pgrp must be foreground',
      );

      expect(stagedProfiles(), hasLength(1));
      final lines1 = File(log).readAsLinesSync();
      expect(lines1, hasLength(1));
      final record1 = jsonDecode(lines1.single) as Map<String, dynamic>;
      expect(record1['backend'], 'sandbox-exec');
      expect(record1['mode'], 'inheritStdio');
      expect(record1['wait'], isTrue, reason: 'pty caller holds foreground');
      expect((record1['argv'] as List).last, 'u-1');

      // L2 — cache-hit, DIFFERENT volatile argv (C2): same key10, no new
      // staging, no warning, and a BYTE-IDENTICAL spawn record.
      final (exit2, out2) = await startPty(
        ['tty1', '--session', 'u-2-sentinel-different-argv'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(exit2, 0, reason: out2);
      expect(out2, contains('RAW-OK'), reason: 'cache-hit keeps raw mode');
      expect(out2, isNot(contains('provenance refreshed')));
      expect(stagedProfiles(), hasLength(1), reason: 'same key10, no rebuild');
      final lines2 = File(log).readAsLinesSync();
      expect(lines2, hasLength(2));
      expect(
        lines2[1],
        lines2[0],
        reason: 'AC2: fresh vs cache-hit spawn identical',
      );

      // L3 — emit-identical edit (description only): SAME key10, loud
      // provenance re-tie (#70), spawn still identical, raw mode intact.
      final manifestPath = '$proj/.cube-sandbox/tty1.yaml';
      File(manifestPath).writeAsStringSync(
        File(manifestPath).readAsStringSync().replaceFirst(
          '  name: tty1\n',
          '  name: tty1\n  description: edited\n',
        ),
      );
      final (exit3, out3) = await startPty(
        ['tty1', '--session', 'u-3'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(exit3, 0, reason: out3);
      expect(out3, contains('RAW-OK'), reason: 'after-edit keeps raw mode');
      expect(out3, contains('provenance refreshed'), reason: '#70 loudness');
      expect(
        stagedProfiles(),
        hasLength(1),
        reason: 'emit-identical: same key',
      );
      final lines3 = File(log).readAsLinesSync();
      expect(lines3, hasLength(3));
      expect(lines3[2], lines3[0], reason: 'same emit => same spawn record');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  kernelPtyTest(
    'E2E-3/AC3: a real emit-input change rebuilds under a NEW key and '
    'raw mode survives the rebuild path',
    () async {
      final log = '$proj/spawn.jsonl';
      writeManifest('tty2');
      final (exit1, out1) = await startPty(
        ['tty2'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(exit1, 0, reason: out1);
      expect(out1, contains('RAW-OK'));
      final key1 = RegExp(r'profile ([0-9a-f]{10})').firstMatch(out1)![1]!;
      expect(stagedProfiles(), hasLength(1));

      // Widen extraWrite — a pinned emit input (#69): lawful rebuild.
      writeManifest('tty2', extraWrite: '\n  extraWrite: [~/.codemie]');
      final (exit2, out2) = await startPty(
        ['tty2'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log},
      );
      expect(exit2, 0, reason: out2);
      expect(out2, contains('RAW-OK'), reason: 'rebuild path keeps raw mode');
      final key2 = RegExp(r'profile ([0-9a-f]{10})').firstMatch(out2)![1]!;
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
    timeout: const Timeout(Duration(minutes: 2)),
  );

  kernelPtyTest(
    'E2/#53: --spawn-exit forces spawn-and-exit from a terminal',
    () async {
      final log = '$proj/spawn.jsonl';
      final mark = '$proj/spawn-exit-done';
      final markSh = writeScript('marker', 'sleep 3\nprintf done > "\$MARK"\n');
      File('$proj/.cube-sandbox/tty3.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: tty3
spec:
  command:
    - /bin/sh
    - $markSh
  agentRoot: $proj
''');
      final (exit, out) = await startPty(
        ['tty3', '--spawn-exit'],
        extraEnv: {'CUBE_SANDBOX_SPAWN_LOG': log, 'MARK': mark},
      );
      expect(exit, 0, reason: out);
      expect(
        File(mark).existsSync(),
        isFalse,
        reason: 'launcher exited 0 without waiting for the harness',
      );
      final lines = File(log).readAsLinesSync();
      expect(jsonDecode(lines.single)['wait'], isFalse);
      // The orphaned harness still finishes on the inherited fds.
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!File(mark).existsSync() && DateTime.now().isBefore(deadline)) {
        sleep(const Duration(milliseconds: 50));
      }
      expect(File(mark).readAsStringSync(), 'done');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  kernelTest(
    'E6/#81: SIGINT to the waiting launcher surfaces the harness death (130)',
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
          'tty4',
          '--wait',
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
            'the HARNESS trap (130) is the exit — the launcher must '
            'not die of its own SIGINT first',
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
    expect(r.exitCode, 0, reason: r.stderr as String);
    expect(r.stdout as String, contains('RAW-OK'));
  }, skip: skipPty);
}
