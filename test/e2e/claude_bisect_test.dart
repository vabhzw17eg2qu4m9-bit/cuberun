@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// Issue #139 bisect round 2 (read-candidates): drive the
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

      // Read-candidate bisect (round 2): A=BOOT B=BOOT C=SPIN is read —
      // add candidate READ grants to the preset profile, freshest HOME
      // per leg.
      final tzExtra = [
        '(allow file-read* (subpath "/var/db/timezone"))',
        '(allow file-read* (subpath "/private/var/db/timezone"))',
        '(allow file-read* (literal "/etc/localtime"))',
      ].join('\n');
      final matrix = <String>[];
      for (final leg in ['TZ', 'LIB', 'USERS']) {
        final home = Directory('${tmp.path}/home-$leg')..createSync();
        Directory('${tmp.path}/proj-$leg').createSync();
        final tmpReal = Directory.systemTemp.resolveSymbolicLinksSync();
        var text = emitProfile(
          resolveRuntime(
            HarnessPresets.load('claude'),
            services: const {},
            cwd: '${tmp.path}/proj-$leg',
            home: home.path,
            env: {'HOME': home.path, 'TMPDIR': tmpReal},
          ),
        ).text;
        switch (leg) {
          case 'TZ':
            text += '$tzExtra\n';
          case 'LIB':
            final libLines = [
              ...bothSpellingsOf('${home.path}/Library'),
            ].map((p) => '(allow file-read* (subpath "$p"))').join('\n');
            text += '$libLines\n';
          default:
            text = text
                .split('\n')
                .where(
                  (l) =>
                      !(l.startsWith('(deny file-read*') &&
                          l.contains('/Users')),
                )
                .join('\n');
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
        final v = verdict?.group(1) ?? 'UNKNOWN(${r.exitCode})';
        matrix.add('leg=$leg verdict=$v');
        Directory('build/harness-artifacts').createSync(recursive: true);
        if (File(log).existsSync()) {
          File(log).copySync('build/harness-artifacts/claude-bisect-$leg.log');
        }
      }

      // ignore: avoid_print
      print('BISECT-MATRIX ${matrix.join(' | ')}');
      // Round-1 verdict: A=BOOT B=BOOT C=SPIN pinned the preset
      // READ-denies; round-2: TZ=BOOT LIB=SPIN USERS=SPIN pinned
      // /var/db/timezone (ICU tzset at static init). The base profile
      // now grants it — all legs must BOOT. A SPIN regression here
      // (e.g. the tz re-allow removed) is the issue-#139 wedge family
      // returning: red with the matrix, transcripts archived.
      final booted = verdicts.values.every((v) => v == 'BOOT');
      expect(
        booted,
        isTrue,
        reason:
            'claude must BOOT under every bisect profile — a SPIN means '
            'the tz read-grant (or a sibling system re-allow) regressed '
            'or a new boot-path denial appeared. Matrix: '
            '${matrix.join(' | ')}. Key: preset READ denies starved '
            'ICU tzset (/var/db/timezone) at static init — denied read '
            'sent Bun/JIT into a silent 100%-CPU trap/handler retry '
            'before main (issue #139). Transcripts archived.',
      );
    },
    skip: skipKernel ?? false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
