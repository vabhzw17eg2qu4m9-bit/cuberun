@Tags(['integration'])
library;

import 'dart:io';

import 'package:cuberun/src/harness_manifest.dart';
import 'package:cuberun/src/runtime.dart';
import 'package:cuberun/src/probe.dart';
import 'package:cuberun/src/sbpl.dart';
import 'package:cuberun/src/service_grants.dart';
import 'package:cuberun/src/stage.dart';
import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC6 — live boundary on a macOS arm64 host: the full probe passes AND a
/// sabotaged profile makes the probe FAIL (negative control).
/// AC10 — `--use-github` variant: gh config readable, NOT writable, rest
/// of $HOME still denied.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  HarnessRuntime baseRuntime(String projDir, String home) => resolveRuntime(
    HarnessSpec(name: 'pi', command: ['pi'], agentRoot: '~/.pi'),
    services: const {},
    cwd: projDir,
    home: home,
    env: {'HOME': home, 'TMPDIR': Directory.systemTemp.path},
    fs: _RealIO(),
  );

  test(
    'AC6: full probe passes on the real backend',
    () async {
      final tmp = await Directory.systemTemp.createTemp('cuberun-probe-');
      addTearDown(() => tmp.delete(recursive: true));
      final rt = baseRuntime(tmp.path, tmp.path);
      final profile = emitProfile(rt);
      final path = stageProfile(
        cacheDir: projectCacheDir(tmp.path),
        text: profile.text,
        key10: profile.key10,
      );
      final report = await probeHarness(
        runtime: rt,
        profilePath: path,
        home: tmp.path,
      );
      expect(
        report.checks.map((c) => '${c.ok ? 'ok' : 'FAIL'} ${c.name} ${c.info}'),
        everyElement(startsWith('ok')),
        reason:
            'probe report:\n'
            '${report.checks.map((c) => '${c.ok ? 'ok' : 'FAIL'} ${c.name} ${c.info}').join('\n')}',
      );
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'AC6 negative control: sabotaged profile FAILS the probe',
    () async {
      final tmp = await Directory.systemTemp.createTemp('cuberun-neg-');
      addTearDown(() => tmp.delete(recursive: true));
      final rt = baseRuntime(tmp.path, tmp.path);
      final profile = emitProfile(rt);
      // Sabotage: append a trailing allow-all-writes rule — last match wins
      // in SBPL, so writes escape. The probe MUST catch it.
      final badText = '${profile.text}(allow file-write*)\n';
      final badPath = stageProfile(
        cacheDir: projectCacheDir(tmp.path),
        text: badText,
        key10: 'sabotaged0',
      );
      final report = await probeHarness(
        runtime: rt,
        profilePath: badPath,
        home: tmp.path,
      );
      expect(
        report.allPassed,
        isFalse,
        reason: 'sabotaged profile must fail the probe',
      );
      expect(
        report.checks.any((c) => !c.ok && c.name.contains('write outside')),
        isTrue,
        reason: 'the escape-write check is the one that must trip',
      );
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'AC10 E2E: --use-github grants are read-only, rest of HOME denied',
    () async {
      final tmp = await Directory.systemTemp.createTemp('cuberun-ghgrant-');
      addTearDown(() => tmp.delete(recursive: true));
      final home = tmp.path;
      final ghConfig = Directory('$home/.config/gh');
      ghConfig.createSync(recursive: true);
      File(
        '${ghConfig.path}/hosts.yml',
      ).writeAsStringSync('github.com:\n  user: test\n');
      Directory('$home/.elsewhere').createSync();

      final grants = resolveServiceGrants({'github'}, home: home);
      final rt = resolveRuntime(
        HarnessSpec(name: 'pi', command: ['pi'], agentRoot: '~/.pi'),
        services: const {'github'},
        cwd: tmp.path,
        home: home,
        env: {'HOME': home, 'TMPDIR': Directory.systemTemp.path},
        fs: _RealIO(),
      ).withGrants(read: grants.read); // ensure exact catalog folders
      final profile = emitProfile(rt);
      final path = stageProfile(
        cacheDir: projectCacheDir(tmp.path),
        text: profile.text,
        key10: profile.key10,
      );

      Future<String> sh(String script) async {
        final r = await Process.run('/usr/bin/sandbox-exec', [
          '-f',
          path,
          '/bin/bash',
          '-c',
          script,
        ]);
        return '${r.exitCode}\n${r.stdout}${r.stderr}';
      }

      final readOk = await sh('cat ${_q('$home/.config/gh/hosts.yml')}');
      expect(readOk, startsWith('0\n'));
      expect(readOk, contains('user: test'));

      final writeAttempt = await sh('touch ${_q('$home/.config/gh/newfile')}');
      expect(writeAttempt, isNot(startsWith('0')));
      expect(File('$home/.config/gh/newfile').existsSync(), isFalse);

      final elsewhere = await sh('cat ${_q('$home/.elsewhere')} 2>&1; true');
      expect(elsewhere, isNot(contains('elsewhere file')));

      final profileText = profile.text;
      expect(
        profileText,
        contains('(allow file-read* (subpath "$home/.config/gh"))'),
      );
      expect(
        profileText
            .split('\n')
            .where((l) => l.contains('file-write') && l.contains('.config/gh')),
        isEmpty,
      );
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

String _q(String s) => "'${s.replaceAll("'", "'\"'\"'")}'";

final class _RealIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => File(path).existsSync();

  @override
  String? shebangInterpreter(String path) => null;

  @override
  String? realpath(String path) {
    try {
      return File(path).existsSync()
          ? File(path).resolveSymbolicLinksSync()
          : Directory(path).resolveSymbolicLinksSync();
    } catch (_) {
      return path;
    }
  }
}
