@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// Issue #139 bisect (chief-directed, one decisive CI cycle): drive the
/// SAME claude binary under THREE hand-written profiles and classify
/// boot vs silent spin — claude 2.1.314 spins ~100% CPU in dyld/start
/// frames (signal storm in JIT code) under the preset on CI runners
/// while the UNCONFINED control passes the full protocol.
///
/// (A) `(allow default)` bare — no denies at all.
/// (B) (A) + blanket write deny + our known write family re-allowed
///     (home both spellings, /tmp/claude, /tmp/cc-socks, $TMPDIR).
/// (C) the shipped preset profile (resolved from the lib, same facts).
///
/// Verdict matrix (printed + failed-with, never silent):
/// - A spins => being sandboxed AT ALL triggers a Bun early-init
///   trap/handler retry (seatbelt presence detection) — claude-side
///   workaround territory, E2E becomes skip-with-reason citing upstream.
/// - A boots, B spins => a write denial beyond our grant list — diff
///   what else it writes, iterate grants.
/// - A+B boot, C spins => our preset's READ denies (/Users,
///   /private/var blanket) starve some boot path (~/Library prefs,
///   /private/var/db/timezone…) — grant read candidates.
void main() {
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

  final skipKernel = hGuard();

  String? hGuard() {
    if (!Platform.isMacOS) return 'macOS only (SBPL kernel backend)';
    if (!Platform.version.contains('arm64')) {
      return 'arm64 macOS only (claude-code-darwin-arm64 package)';
    }
    if (!File('/usr/bin/expect').existsSync()) {
      return '/usr/bin/expect not available (pty driver)';
    }
    return null;
  }

  test(
    'issue #139 bisect: A bare / B write-family / C preset profile',
    () {
      final tmp = Directory.systemTemp.createTempSync('cube-claude-bisect-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final claudeDir = installNativeClaude(Directory('${tmp.path}/claude'));
      final claudeBin = '$claudeDir/claude';

      final script = File('${tmp.path}/probe.exp');
      script.writeAsStringSync(r'''
#!/usr/bin/expect -f
# Boot probe: does claude produce ANY output within 45s under profile
# $env(PROFILE)? Verdict on stdout; transcripts logged to TTY_LOG.
set timeout 45
log_file $env(TTY_LOG)
spawn /usr/bin/sandbox-exec -f $env(PROFILE) $env(CLAUDE_BIN)
catch {exec stty -echo < $spawn_out(slave,name)}
catch {exec stty rows 40 columns 120 < $spawn_out(slave,name)}
expect {
    timeout {
        puts "\nVERDICT: SPIN"
        catch {exec ps -o pid,time,pcpu,command -p [exp_pid]}
        catch {exec kill -9 [exp_pid]}
        exit 4
    }
    eof { puts "\nVERDICT: EXITED"; exit 5 }
    -re {.} {
        puts "\nVERDICT: BOOT"
        catch {exec kill -9 [exp_pid]}
        exit 0
    }
}
''');

      // Profile per leg, each with a FRESH HOME (fair first-boot state).
      final matrix = <String>[];
      final verdicts = <String, String>{};
      for (final leg in ['A', 'B', 'C']) {
        final home = Directory('${tmp.path}/home-$leg')..createSync();
        Directory('${tmp.path}/proj-$leg').createSync();
        String text;
        switch (leg) {
          case 'A':
            text = '(version 1)\n(allow default)\n';
          case 'B':
            final bothHome = bothSpellingsOf(home.path);
            final tmpReal = Directory.systemTemp.resolveSymbolicLinksSync();
            text =
                '(version 1)\n(allow default)\n'
                '(deny file-write*)\n'
                '${[...bothHome, ...bothSpellingsOf('/tmp/claude'), ...bothSpellingsOf('/tmp/cc-socks'), ...bothSpellingsOf(tmpReal)].map((p) => '(allow file-write* (subpath "$p"))').join('\n')}\n';
          default:
            text = emitProfile(
              resolveRuntime(
                HarnessPresets.load('claude'),
                services: const {},
                cwd: '${tmp.path}/proj-$leg',
                home: home.path,
                env: {
                  'HOME': home.path,
                  'TMPDIR': Directory.systemTemp.resolveSymbolicLinksSync(),
                },
              ),
            ).text;
        }
        final profile = File('${tmp.path}/$leg.sb')..writeAsStringSync(text);
        final log = '${tmp.path}/$leg.log';
        final r = Process.runSync(
          '/usr/bin/expect',
          [script.path],
          workingDirectory: '${tmp.path}/proj-$leg',
          environment: {
            'PATH': '$claudeDir:/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': home.path,
            'TERM': 'xterm-256color',
            'COLUMNS': '120',
            'LINES': '40',
            'ANTHROPIC_API_KEY': 'sk-ant-dummy-claude-tty-e2e',
            'PROFILE': profile.path,
            'CLAUDE_BIN': claudeBin,
            'TTY_LOG': log,
          },
        );
        final verdict = RegExp(r'VERDICT: (\w+)').firstMatch(r.stdout);
        verdicts[leg] = verdict?.group(1) ?? 'UNKNOWN(${r.exitCode})';
        matrix.add('leg=$leg verdict=${verdicts[leg]} exit=${r.exitCode}');
        Directory('build/harness-artifacts').createSync(recursive: true);
        if (File(log).existsSync()) {
          File(log).copySync('build/harness-artifacts/claude-bisect-$leg.log');
        }
      }

      // ignore: avoid_print
      print('BISECT-MATRIX ${matrix.join(' | ')}');
      fail(
        'BISECT-MATRIX ${matrix.join(' | ')} — interpretation: '
        'A spins => seatbelt-presence trigger in Bun early init '
        '(claude-side workaround, E2E skips citing upstream); '
        'A boots + B spins => write denial beyond the grant list '
        '(diff writes, iterate grants); A+B boot + C spins => preset '
        'READ denies starve a boot path (grant ~/Library prefs, '
        '/private/var/db/timezone candidates). Transcripts archived.',
      );
    },
    skip: skipKernel ?? false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
