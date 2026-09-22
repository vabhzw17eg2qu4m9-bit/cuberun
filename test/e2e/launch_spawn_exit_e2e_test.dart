@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #53 — launch becomes spawn-and-exit: once the confined harness
/// is running, cube-sandbox is GONE (exit 0 = spawn success, 126 =
/// fail-closed, nothing ran). Nothing after spawn depends on the
/// launcher: the kernel keeps the boundary (E2E-3), inherited fds keep
/// flowing (E2E-4), the terminal keeps Ctrl-C (E2E-5), launchd keeps the
/// orphan (E2E-7). `--wait` preserves the blocking contract verbatim
/// (E2E-6); the emitted SBPL is byte-identical across modes (IT-1).
/// Runs the compiled binary against the real sandbox-exec backend —
/// skips loudly when the host cannot apply profiles.
void main() {
  /// Why the kernel suites cannot run on this host right now (never silent).
  final String? skipKernel = h.nestedSandboxDeniedReason();

  /// A kernel-boundary test: declared with the loud skip reason baked in.
  void kernelTest(String name, dynamic Function() body) =>
      test(name, body, skip: skipKernel);

  late Directory tmp;
  late Directory home;
  late String proj;
  late String argvSh;

  /// Harness script `name` with [body]; paths arrive via the inherited env.
  String script(String name, String body) {
    final p = '$proj/$name.sh';
    File(p).writeAsStringSync('#!/bin/sh\n$body\n');
    Process.runSync('chmod', ['+x', p]);
    return p;
  }

  /// Profile `name` whose harness command is [cmd] (argv list, agentRoot
  /// = the project dir — every marker write stays inside the grants).
  void writeProfile(String name, List<String> cmd) {
    final argv = cmd.map((a) => '    - $a').join('\n');
    File('$proj/.cube-sandbox/$name.yaml').writeAsStringSync('''
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: $name
spec:
  command:
$argv
  agentRoot: $proj
''');
  }

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('cube-sandbox-spawn-');
    home = Directory.systemTemp.createTempSync('cube-sandbox-home-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    addTearDown(() => home.deleteSync(recursive: true));
    proj = '${tmp.path}/proj';
    Directory('$proj/.cube-sandbox').createSync(recursive: true);
    argvSh = script('argv.sh', '''
if [ "\$1" = "__exit" ]; then shift; exit "\$1"; fi
if [ "\$1" = "__int" ]; then kill -INT "\$\$"; sleep 5; fi
for a in "\$@"; do
  printf '%s\n' "\$a"
done
''');
  });

  Map<String, String> env([Map<String, String>? extra]) => {
    'HOME': home.path,
    ...?extra,
  };

  /// Starts the compiled launcher for [args]; caller drains/joins pipes
  /// (the orphaned harness holds the fds and writes after cube's exit).
  Future<Process> startLauncher(
    List<String> args, {
    Map<String, String>? extraEnv,
  }) {
    return Process.start(
      h.ensureBinary(),
      ['launch', ...args],
      workingDirectory: proj,
      environment: env(extraEnv),
    );
  }

  /// Polls [path] into existence (≤ [timeout]); false on timeout.
  bool awaitFile(
    String path, {
    Duration timeout = const Duration(seconds: 30),
  }) {
    final f = File(path);
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (f.existsSync()) return true;
      sleep(const Duration(milliseconds: 50));
    }
    return f.existsSync();
  }

  kernelTest(
    'E2E-1/AC1: launcher exits 0 while the harness is still running',
    () async {
      final mark = '$proj/mark1.txt';
      writeProfile('spawn1', [
        script('h1.sh', 'sleep 6\nprintf done > "\$MARK"\n'),
      ]);
      final p = await startLauncher(['spawn1'], extraEnv: {'MARK': mark});
      // Order matters: the launcher's exit must be observed BEFORE any
      // pipe join — the orphan harness holds the fds, so join() EOF only
      // happens when the HARNESS exits.
      expect(await p.exitCode, 0);
      expect(
        File(mark).existsSync(),
        isFalse,
        reason: 'harness (sleep 6) must outlive the launcher',
      );
      expect(
        awaitFile(mark),
        isTrue,
        reason: 'harness finishes after cube died',
      );
      expect(File(mark).readAsStringSync(), 'done');
      // Only now drain: banner bytes are buffered; EOF at harness exit.
      final errOut = await p.stderr.transform(utf8.decoder).join();
      expect(
        errOut,
        contains('under cube-sandbox'),
        reason: 'banner before exit',
      );
    },
  );

  kernelTest(
    'E2E-2/AC2: launch exit = spawn status (0 even at harness 7); 126 fail-closed',
    () {
      writeProfile('spawn2', [argvSh]);
      final r0 = h.launchCubeSandbox(
        ['launch', 'spawn2', '__exit', '0'],
        cwd: proj,
        env: env(),
      );
      expect(r0.exit, 0, reason: 'stderr: ${r0.stderr}');
      final r7 = h.launchCubeSandbox(
        ['launch', 'spawn2', '__exit', '7'],
        cwd: proj,
        env: env(),
      );
      expect(
        r7.exit,
        0,
        reason: 'spawn succeeded — harness exit 7 is not ours',
      );
      final rFail = h.launchCubeSandbox(
        ['launch', 'spawn2'],
        cwd: proj,
        env: env({'PATH': '/nonexistent'}),
      );
      expect(rFail.exit, 126, reason: 'stderr: ${rFail.stderr}');
      expect(rFail.stderr, contains('fail closed'));
    },
  );

  kernelTest(
    'E2E-3/AC3+F1: confinement survives the launcher; unconfined control writes',
    () async {
      // The denied target must sit OUTSIDE every grant — notably OUTSIDE
      // realpath($TMPDIR): systemTemp itself is a WRITE grant, so an evil
      // dir under it would prove nothing. One level above it is granted
      // to the user (the unconfined control can create it) but not to
      // the profile.
      final evilBase = Directory.systemTemp.parent.path;
      final evilC = '$evilBase/${tmp.path.split('/').last}-evil-confined';
      final evilN = '$evilBase/${tmp.path.split('/').last}-evil-unconfined';
      Directory(evilC).createSync();
      Directory(evilN).createSync();
      addTearDown(() {
        Directory(evilC).deleteSync(recursive: true);
        Directory(evilN).deleteSync(recursive: true);
      });
      final h3 = script(
        'h3.sh',
        'printf allowed > "\$MARKDIR/allowed.txt"\n'
            'sleep 3\n'
            'printf evil > "\$EVIL/evil.txt" 2>/dev/null\n'
            'printf done > "\$MARKDIR/done3.txt"\n',
      );
      writeProfile('spawn3', [h3]);

      // Confined: the launcher is dead long before the outside write fires.
      final p = await startLauncher(
        ['spawn3'],
        extraEnv: {'MARKDIR': proj, 'EVIL': evilC},
      );
      expect(await p.exitCode, 0);
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
      expect(
        awaitFile('$proj/done3.txt'),
        isTrue,
        reason: 'harness finished after cube died',
      );
      expect(File('$proj/allowed.txt').readAsStringSync(), 'allowed');
      expect(
        File('$evilC/evil.txt').existsSync(),
        isFalse,
        reason: 'write outside every grant denied WITHOUT a living launcher',
      );

      // Negative control: the identical command without the profile writes.
      final r = await Process.run(
        h3,
        const [],
        workingDirectory: proj,
        environment: {'MARKDIR': proj, 'EVIL': evilN},
      );
      expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
      expect(
        File('$evilN/evil.txt').existsSync(),
        isTrue,
        reason: 'the capture detects non-confinement',
      );
    },
  );

  kernelTest(
    'E2E-4/AC4+F2: harness output reaches the terminal after cube exits',
    () async {
      writeProfile('spawn4', [
        script('h4.sh', 'sleep 2\necho after-parent-death'),
      ]);
      final p = await startLauncher(['spawn4']);
      expect(await p.exitCode, 0);
      final out = await p.stdout.transform(utf8.decoder).join();
      expect(
        out,
        contains('after-parent-death'),
        reason:
            'bytes written after the launcher died reach the inherited stdout',
      );

      // Negative control: the same harness with stdio closed produces nothing.
      writeProfile('spawn4b', [
        script('h4b.sh', 'exec 1>&-\nexec 2>&-\nsleep 1\necho invisible'),
      ]);
      final q = await startLauncher(['spawn4b']);
      expect(await q.exitCode, 0);
      expect(
        await q.stdout.transform(utf8.decoder).join(),
        isEmpty,
        reason: 'capture guard: closed stdio must produce nothing',
      );
    },
  );

  kernelTest(
    'E2E-5/AC5+F3: SIGINT reaches the harness after cube exits (foreign-group control)',
    () async {
      final perl = '/usr/bin/perl';
      if (!File(perl).existsSync()) {
        markTestSkipped(
          '/usr/bin/perl missing — cannot isolate a process group',
        );
      }

      /// setpgrp(0,0) gives the subtree its own group (pgid == pid, kept by
      /// exec) — the test process itself stays OUT of the signaled group.
      Future<Process> spawnIsolated(String profile, String markDir) =>
          Process.start(
            perl,
            [
              '-e',
              'setpgrp(0, 0); exec @ARGV',
              '--',
              h.ensureBinary(),
              'launch',
              profile,
            ],
            workingDirectory: proj,
            environment: env({'MARKDIR': markDir}),
          );

      final body =
          'trap \'printf trapped > "\$MARKDIR/INT"\' INT\n'
          'sleep 8 &\n'
          'wait \$!\n'
          'printf done > "\$MARKDIR/DONE"\n';
      Directory('$proj/a5').createSync();
      Directory('$proj/b5').createSync();

      // Positive: INT to the group after cube's exit reaches the trap.
      writeProfile('spawn5', [script('h5.sh', body)]);
      final p = await spawnIsolated('spawn5', '$proj/a5');
      // Order matters: observe the launcher's exit FIRST (the pipe EOF
      // only comes when the harness exits — draining before the kill
      // would find an EMPTY group).
      expect(await p.exitCode, 0, reason: 'launcher gone, group stays alive');
      final g = p.pid; // pgid == launcher pid (setpgrp before exec)
      final kill1 = Process.runSync('kill', ['-s', 'INT', '-$g']);
      expect(kill1.exitCode, 0, reason: 'stderr: ${kill1.stderr}');
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
      expect(
        awaitFile('$proj/a5/DONE'),
        isTrue,
        reason: 'trap survived, script continued',
      );
      expect(File('$proj/a5/INT').readAsStringSync(), 'trapped');

      // Negative control: the same INT to a FOREIGN live group — no marker.
      final foreign = await Process.start(perl, [
        '-e',
        'setpgrp(0, 0); exec @ARGV',
        '--',
        '/bin/sleep',
        '30',
      ]);
      writeProfile('spawn5b', [script('h5b.sh', body)]);
      final q = await spawnIsolated('spawn5b', '$proj/b5');
      expect(await q.exitCode, 0);
      final kill2 = Process.runSync('kill', ['-s', 'INT', '-${foreign.pid}']);
      expect(
        kill2.exitCode,
        0,
        reason: 'signal fired at the foreign group only',
      );
      await q.stdout.drain<void>();
      await q.stderr.drain<void>();
      expect(
        awaitFile('$proj/b5/DONE'),
        isTrue,
        reason: 'arm-2 harness finished naturally',
      );
      expect(
        File('$proj/b5/INT').existsSync(),
        isFalse,
        reason: 'a signal to a foreign group must not reach this harness',
      );
    },
  );

  kernelTest(
    'E2E-6/AC7: --wait forwards the child exit verbatim (0 / 7 / 130)',
    () {
      writeProfile('spawn6', [argvSh]);
      expect(
        h
            .launchCubeSandbox(
              ['launch', '--wait', 'spawn6', '__exit', '0'],
              cwd: proj,
              env: env(),
            )
            .exit,
        0,
      );
      expect(
        h
            .launchCubeSandbox(
              ['launch', '--wait', 'spawn6', '__exit', '7'],
              cwd: proj,
              env: env(),
            )
            .exit,
        7,
      );
      expect(
        h
            .launchCubeSandbox(
              ['launch', '--wait', 'spawn6', '__int'],
              cwd: proj,
              env: env(),
            )
            .exit,
        130,
        reason: 'SIGINT => 128+2',
      );
    },
  );

  kernelTest(
    'E2E-7/AC6+F4: the orphaned harness reparents to launchd (ppid 1)',
    () async {
      // The harness publishes its own pid, then sleeps to give the test a
      // window; the LIVE ppid is measured by `ps` from the UNCONFINED test
      // process (ps under the profile is not reliable on newer macOS).
      writeProfile('spawn7', [
        script(
          'h7.sh',
          'printf "\$\$" > "\$MARKDIR/pid7.txt"\n'
              'sleep 8\n'
              'printf done > "\$MARKDIR/done7.txt"\n',
        ),
      ]);
      final p = await startLauncher(['spawn7'], extraEnv: {'MARKDIR': proj});
      expect(await p.exitCode, 0);
      expect(File('$proj/pid7.txt').existsSync(), isTrue);

      int? ppid;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (DateTime.now().isBefore(deadline)) {
        final pid = int.tryParse(
          File('$proj/pid7.txt').readAsStringSync().trim(),
        );
        if (pid != null) {
          final r = Process.runSync('ps', ['-o', 'ppid=', '-p', '$pid']);
          ppid = int.tryParse((r.stdout as String).trim());
          if (ppid != null) break;
        }
        if (File('$proj/done7.txt').existsSync()) break;
        sleep(const Duration(milliseconds: 50));
      }
      expect(
        ppid,
        1,
        reason:
            'orphan reparents to launchd (F4; attribution only — '
            'nothing polls or reaps)',
      );
      expect(
        awaitFile('$proj/done7.txt'),
        isTrue,
        reason: 'harness survived the launcher',
      );
      await p.stdout.drain<void>();
      await p.stderr.drain<void>();
    },
  );

  kernelTest(
    'IT-1/AC8: staged SBPL byte-identical across default, --wait and sbpl',
    () {
      writeProfile('spawn8', [argvSh]);
      final sbpl = h.launchCubeSandbox(
        ['sbpl', 'spawn8'],
        cwd: proj,
        env: env(),
      );
      expect(sbpl.exit, 0, reason: sbpl.stderr);
      final r1 = h.launchCubeSandbox(
        ['launch', 'spawn8', 'plain-tail'],
        cwd: proj,
        env: env(),
      );
      expect(r1.exit, 0, reason: r1.stderr);
      final r2 = h.launchCubeSandbox(
        ['launch', '--wait', 'spawn8', 'plain-tail'],
        cwd: proj,
        env: env(),
      );
      expect(r2.exit, 0, reason: r2.stderr);
      final staged = Directory('$proj/.cube-sandbox/cache')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sb'))
          .toList();
      expect(
        staged,
        hasLength(1),
        reason: 'mode is not an emit input — same key10',
      );
      expect(staged.single.readAsStringSync(), sbpl.stdout);
    },
  );

  test('IT-2/AC9: usage and README document spawn-and-exit and --wait', () {
    final help = Process.runSync(h.ensureBinary(), ['--help']);
    final text = '${help.stdout}${help.stderr}';
    expect(text, contains('--wait'));
    expect(
      text,
      matches(RegExp('spawn-and-exit', caseSensitive: false)),
      reason: 'usage text must state the new default',
    );
    final readme = File('README.md').readAsStringSync();
    expect(readme, contains('--wait'));
    expect(readme, contains('spawn-and-exit'));
  });
}
