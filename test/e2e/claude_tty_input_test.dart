@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Issue #139 — the claude preset's runtime proof: keyboard input must
/// SURVIVE the post-onboarding config persist inside
/// `cube-sandbox launch claude`.
///
/// v0.7.0 regression: Claude Code persists ~/.claude.json atomically with
/// RANDOM siblings (`~/.claude.json.tmp.<rand>`, `~/.claude.json.lock`,
/// `~/.claude.json.backup`) — literal extraWrite entries cannot enumerate
/// them, the first post-onboarding persist hits the write deny, and the
/// TUI stops consuming keystrokes (issue repro: only kill -9 works).
///
/// The driver installs the official native binary straight from the npm
/// platform package (`@anthropic-ai/claude-code-darwin-arm64` registry
/// tarball — no npm needed), then drives `launch claude` under
/// /usr/bin/expect on a real pty: pass the onboarding dialogs with three
/// spaced Enters, type the marker `hellotest123`, and require it DRAWN
/// back (pty echo is killed — a wedged-but-echoing pty cannot fake input
/// flow). The harness process must still be ALIVE right before the kill.
///
/// Attribution: on a confined failure the SAME binary is driven
/// UNCONFINED under the same driver/fresh HOME. Control renders => the
/// failure is sandbox-attributable (stays red); control spins too =>
/// this host cannot drive the claude TUI at all (loud skip, owner
/// validates live). Red on the unfixed preset, green with the prefix
/// grants.
void main() {
  final skipKernel = h.nestedSandboxDeniedReason();

  String? hostReason() {
    if (!Platform.isMacOS) return 'macOS only (SBPL kernel backend)';
    if (!Platform.version.contains('arm64')) {
      return 'arm64 macOS only — the npm platform package driven here is '
          'claude-code-darwin-arm64';
    }
    if (!File('/usr/bin/expect').existsSync()) {
      return '/usr/bin/expect not available (pty driver)';
    }
    return null;
  }

  /// Installs the native claude binary from the npm registry tarball;
  /// returns the directory to put on PATH (the one holding `claude`).
  String installNativeClaude(Directory into) {
    into.createSync(recursive: true);
    final meta = Process.runSync('curl', [
      '-fsSL',
      'https://registry.npmjs.org/@anthropic-ai/claude-code-darwin-arm64/latest',
    ]);
    if (meta.exitCode != 0) {
      throw StateError('registry metadata fetch failed: ${meta.stderr}');
    }
    final parsed = jsonDecode(meta.stdout as String) as Map<String, dynamic>;
    final tarball =
        (parsed['dist'] as Map<String, dynamic>)['tarball'] as String;
    final tgz = '${into.path}/claude.tgz';
    final dl = Process.runSync('curl', ['-fsSL', '-o', tgz, tarball]);
    if (dl.exitCode != 0) {
      throw StateError('tarball fetch failed: ${dl.stderr}');
    }
    Process.runSync('tar', ['-xzf', tgz, '-C', into.path]);
    final bin = File('${into.path}/package/claude');
    if (!bin.existsSync()) {
      throw StateError('no claude binary at package/claude in the tarball');
    }
    Process.runSync('chmod', ['+x', bin.path]);
    return bin.parent.path;
  }

  /// TUI transcripts are escape-sequence soup; strip CSI/OSC/charset and
  /// stray escapes so the marker can be matched as typed.
  String stripAnsi(String s) {
    var out = s
        .replaceAll(RegExp(r'\x1b\[[0-9;?]*[a-zA-Z]'), '')
        .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(\x07|\x1b\\)'), '')
        .replaceAll(RegExp(r'\x1b[()][A-B0]'), '');
    out = out.replaceAll(RegExp(r'\x1b.'), '');
    return out;
  }

  String transcriptTail(String path) {
    final f = File(path);
    if (!f.existsSync()) return '(no transcript written to $path)';
    final t = f.readAsStringSync();
    return t.length <= 4000 ? t : '...${t.substring(t.length - 4000)}';
  }

  test(
    'issue #139: TUI input flows after onboarding under launch claude',
    () async {
      final tmp = Directory.systemTemp.createTempSync('cube-claude-tty-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final home = Directory('${tmp.path}/home')..createSync();
      final proj = Directory('${tmp.path}/proj')..createSync();
      final claudeDir = installNativeClaude(Directory('${tmp.path}/claude'));

      final artifactDir = 'build/harness-artifacts';
      Directory(artifactDir).createSync(recursive: true);
      final stamp = DateTime.now().millisecondsSinceEpoch;

      final script = File('${tmp.path}/drive.exp');
      script.writeAsStringSync(r'''
#!/usr/bin/expect -f
# Drives claude on a pty (issue #139). CTRL=1: spawn the binary DIRECTLY
# (unconfined attribution control); default: `cube-sandbox launch claude`.
set timeout 90
log_file $env(TTY_LOG)
if {[info exists env(CTRL)]} {
    spawn $env(CLAUDE_BIN)
} else {
    spawn $env(CUBE_BIN) launch claude
}

# Kill tty echo: from here the ONLY way the marker can appear in the
# transcript is the TUI itself drawing it — a wedged-but-echoing pty
# cannot fake input flow.
catch {exec stty -echo < $spawn_out(slave,name)}
# Give the pty a real geometry: a 0x0 window sends TUI renderers
# (Ink/React) into a silent 100%-CPU layout loop — measured on CI.
catch {exec stty rows 40 columns 120 < $spawn_out(slave,name)}

expect {
    timeout { puts "\nBOOT-TIMEOUT: claude TUI never produced output"
              catch {exec kill -9 [exp_pid]}; exit 5 }
    eof { puts "\nBOOT-EOF: claude exited during boot"; exit 5 }
    -re {.}
}
puts "\nBOOT-ALIVE pid=[exp_pid]"

# Onboarding: three spaced Enters (theme -> trust -> whatever follows).
sleep 3
send "\r"
sleep 4
send "\r"
sleep 4
send "\r"

# Main chat UI: type the marker; a LIVE input path draws it back.
sleep 3
send "hellotest123"
expect {
    timeout {
        puts "\nMARKER-TIMEOUT: TUI stopped consuming keyboard input (issue #139 symptom)"
        # claude may have exited silently while an orphan child holds
        # the pty (no EOF) — reap its status and snapshot the tree,
        # the socket state, and a stack sample of the live pid.
        catch {puts "WAIT-NOWAIT: [wait -nowait]"}
        set pid [exp_pid]
        catch {puts [exec /bin/sh -c "ps -ef | grep -Ei 'claude|sandbox-exec' | grep -v grep | head -15"]}
        catch {puts [exec /bin/sh -c "lsof -U -p $pid 2>/dev/null | head -25"]}
        catch {puts [exec /bin/sh -c "sample $pid 2 2>/dev/null | sed -n '1,70p'"]}
        catch {puts [exec /bin/sh -c "ls -la /tmp/ /private/tmp/ 2>/dev/null | head -20"]}
        catch {exec kill -9 [exp_pid]}
        exit 4
    }
    eof { puts "\nMARKER-EOF: claude died while typing"; exit 4 }
    -re {h.*e.*l.*l.*o.*t.*e.*s.*t.*1.*2.*3} {}
}

# Input flowed; the harness must still be alive right before the kill.
sleep 2
set pid [exp_pid]
if {[catch {exec kill -0 $pid} err]} {
    puts "\nCLAUDE-DEAD: pid $pid gone ($err)"
    exit 3
}
puts "\nMARKER-OK-ALIVE"
catch {exec kill -9 $pid}
sleep 1
exit 0
''');

      Future<ProcessResult> drive(Map<String, String> extra, String log) =>
          Process.run(
            '/usr/bin/expect',
            [script.path],
            workingDirectory: proj.path,
            environment: {
              // Minimal, CI-var-free env: GitHub injects CI=1/GITHUB_*,
              // and a TUI must not mistake this pty for headless CI.
              'PATH': '$claudeDir:/usr/bin:/bin:/usr/sbin:/sbin',
              'HOME': home.path,
              'TERM': 'xterm-256color',
              'COLUMNS': '120',
              'LINES': '40',
              'ANTHROPIC_API_KEY': 'sk-ant-dummy-claude-tty-e2e',
              'TTY_LOG': log,
              ...extra,
            },
          );

      (ProcessResult, String) archive(ProcessResult r, String log, String tag) {
        final tlog = '$artifactDir/claude-tty-$tag-$stamp.log';
        if (File(log).existsSync()) File(log).copySync(tlog);
        final dout = '$artifactDir/claude-tty-driver-$tag-$stamp.log';
        File(dout).writeAsStringSync(r.stdout);
        return (r, log);
      }

      String cleanTail(String log) => stripAnsi(transcriptTail(log));

      // CONFINED leg first — a fresh box must exercise the preset's
      // fresh-box path, never a state an earlier leg pre-created.
      final (confined, confinedLog) = archive(
        await drive({'CUBE_BIN': h.ensureBinary()}, '${tmp.path}/tui.log'),
        '${tmp.path}/tui.log',
        'confined',
      );
      String confinedReason() =>
          'expect protocol failed (exit ${confined.exitCode}): '
          '${confined.stderr}\ndriver output (incl. stall diagnostics):\n'
          '${confined.stdout}\ntranscript tail:\n'
          '${cleanTail(confinedLog)}';

      var confinedPassed = confined.exitCode == 0;
      if (confinedPassed) {
        final transcript = stripAnsi(File(confinedLog).readAsStringSync());
        // The TUI draws keystrokes interleaved with frame redraws, so a
        // contiguous marker is not guaranteed — require the marker
        // characters IN ORDER (same semantics as the expect-side match;
        // junk between letters is TUI redraw, not echo).
        confinedPassed = RegExp(
          'h.*e.*l.*l.*o.*t.*e.*s.*t.*1.*2.*3',
          dotAll: true,
        ).hasMatch(transcript);
        expect(
          confinedPassed,
          isTrue,
          reason:
              'the typed marker was never drawn back — TUI input path is '
              'dead (issue #139). Transcript tail:\n'
              '${cleanTail(confinedLog)}',
        );
      }

      if (!confinedPassed) {
        // ATTRIBUTION — drive the SAME binary UNCONFINED (same driver,
        // fresh HOME, same pty). Control renders => the failure is
        // sandbox-attributable (stay red). Control spins too => this
        // host cannot drive the claude TUI at all: skip loudly, never
        // silently green (the CI job reports skips as skips).
        final controlLog = '${tmp.path}/control.log';
        final control = await drive({
          'CLAUDE_BIN': '$claudeDir/claude',
          'CTRL': '1',
        }, controlLog);
        archive(control, controlLog, 'control');
        if (control.exitCode != 0) {
          final ctrlTail = cleanTail(controlLog);
          markTestSkipped(
            'claude TUI cannot render even UNCONFINED under this driver '
            'on this host (fresh HOME + expect pty) — environmental, not '
            'sandbox-attributable; owner validates live. Control '
            'transcript tail:\n$ctrlTail',
          );
        }
        fail(confinedReason());
      }

      // ignore: avoid_print
      print(
        'claude TUI transcript archived at '
        '$artifactDir/claude-tty-confined-$stamp.log; '
        'tail:\n${cleanTail(confinedLog)}',
      );
    },
    skip: skipKernel ?? hostReason() ?? false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
