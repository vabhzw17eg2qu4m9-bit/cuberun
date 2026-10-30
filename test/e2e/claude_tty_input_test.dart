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
/// spaced Enters, type the marker `hellotest123`, and require it back in
/// the captured TUI transcript. The harness process must still be ALIVE
/// right before the kill — a crash is a different failure than a wedged
/// TUI. Red on the unfixed preset, green with the `(prefix
/// ~/.claude.json)` grant.
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

      final logPath = '${tmp.path}/tui.log';
      final script = File('${tmp.path}/drive.exp');
      script.writeAsStringSync(r'''
#!/usr/bin/expect -f
# Drives `cube-sandbox launch claude` on a pty (issue #139): onboarding
# Enters -> type the marker -> the marker must be DRAWN by the TUI.
set timeout 90
log_file $env(TTY_LOG)
spawn $env(CUBE_BIN) launch claude

# Kill tty echo: from here the ONLY way the marker can appear in the
# transcript is the TUI itself drawing it — a wedged-but-echoing pty
# cannot fake input flow.
catch {exec stty -echo < $spawn_out(slave,name)}

expect {
    timeout { puts "\nBOOT-TIMEOUT: claude TUI never produced output"
              catch {exec ps -o pid,ppid,stat,etime,command -p [exp_pid]}
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
        set pid [exp_pid]
        catch {exec ps -o pid,ppid,stat,etime,command -p $pid}
        catch {exec /bin/sh -c "sample $pid 2 2>/dev/null | sed -n '1,45p'"}
        catch {exec /bin/sh -c "lsof -p $pid 2>/dev/null | head -30"}
        catch {exec /bin/sh -c "ls -la /tmp/ /private/tmp/ /tmp/claude-501 2>/dev/null | head -25"}
        catch {exec kill -9 $pid}
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

      final r = await Process.run(
        '/usr/bin/expect',
        [script.path],
        workingDirectory: proj.path,
        environment: {
          // Minimal, CI-var-free env: GitHub injects CI=1/GITHUB_*, and a
          // TUI must not mistake this pty session for headless CI.
          'PATH': '$claudeDir:/usr/bin:/bin:/usr/sbin:/sbin',
          'HOME': home.path,
          'TERM': 'xterm-256color',
          'ANTHROPIC_API_KEY': 'sk-ant-dummy-claude-tty-e2e',
          'CUBE_BIN': h.ensureBinary(),
          'TTY_LOG': logPath,
        },
      );

      // The transcript rides the CI harness-artifacts archive (and the
      // failure reasons below) — every red/green verdict is inspectable.
      final artifactDir = 'build/harness-artifacts';
      Directory(artifactDir).createSync(recursive: true);
      final kept =
          '$artifactDir/claude-tty-'
          '${DateTime.now().millisecondsSinceEpoch}.log';
      if (File(logPath).existsSync()) File(logPath).copySync(kept);
      String cleanTail() => stripAnsi(transcriptTail(logPath));
      // expect's own puts (protocol verdicts + stall diagnostics:
      // ps/sample/lsof) lands on ITS stdout — archive it verbatim and
      // put it in every failure reason.
      final driverOut = File(
        '$artifactDir/claude-tty-driver-'
        '${DateTime.now().millisecondsSinceEpoch}.log',
      );
      driverOut.writeAsStringSync(r.stdout);
      String driverTail() {
        final t = r.stdout;
        return t.length <= 5000 ? t : '...${t.substring(t.length - 5000)}';
      }

      expect(
        r.exitCode,
        0,
        reason:
            'expect protocol failed (exit ${r.exitCode}): '
            '${r.stderr}\ndriver output (incl. stall diagnostics):\n'
            '${driverTail()}\ntranscript tail:\n${cleanTail()}',
      );

      final transcript = stripAnsi(File(logPath).readAsStringSync());
      expect(
        transcript,
        contains('hellotest123'),
        reason:
            'the typed marker never echoed back — TUI input path is '
            'dead (issue #139). Transcript tail:\n${cleanTail()}',
      );
      // ignore: avoid_print
      print('claude TUI transcript archived at $kept; tail:\n${cleanTail()}');
    },
    skip: skipKernel ?? hostReason() ?? false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
