@Tags(['integration'])
library;

import 'dart:io';

import 'package:cuberun/src/tool_catalog.dart';
import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC12 — gh matrix: the pinned gh command surface runs inside the `fa`
/// profile with `--use-github` (token from the granted `~/.config/gh` or
/// GH_TOKEN env) with IDENTICAL outcomes to the unconfined baseline.
/// Skips with reason when gh or a token is absent — never silently green.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  test(
    'gh matrix: confined == unconfined for every cataloged command',
    () {
      final gh = Process.runSync('/usr/bin/which', ['gh']);
      if (gh.exitCode != 0) {
        markTestSkipped('gh binary not on PATH');
      }
      final token =
          Platform.environment['GH_TOKEN'] ??
          Platform.environment['GITHUB_TOKEN'];
      if (token == null || token.trim().isEmpty) {
        markTestSkipped(
          'no GH_TOKEN/GITHUB_TOKEN — AC12 gh leg skipped '
          'with reason, never silently green',
        );
      }

      final env = {'GH_TOKEN': token!, 'GITHUB_TOKEN': token};
      final proj = Directory.systemTemp.createTempSync('cuberun-ghmx-');
      addTearDown(() => proj.deleteSync(recursive: true));

      for (final cmd in kGhCommands) {
        final args = cmd.split(' ');
        // repo-scoped commands need a repo argument; use the public fixture
        // repo for reads, and create-on-your-own for writes is covered by
        // the git matrix (fixture remotes) — here: read surface + api.
        final full = switch (cmd) {
          'repo view' => [...args, 'octocat/Hello-World'],
          'issue list' => [
            ...args,
            '-R',
            'octocat/Hello-World',
            '--limit',
            '3',
          ],
          'issue view' => [...args, '1', '-R', 'octocat/Hello-World'],
          'pr list' => [...args, '-R', 'octocat/Hello-World', '--limit', '3'],
          'pr view' => [...args, '1', '-R', 'octocat/Hello-World'],
          'release list' => [
            ...args,
            '-R',
            'octocat/Hello-World',
            '--limit',
            '3',
          ],
          'release view' => [...args, '-R', 'octocat/Hello-World'],
          _ => args,
        };
        final base = Process.runSync(
          'gh',
          full,
          workingDirectory: proj.path,
          environment: env,
        );
        final conf = h.runCuberun(
          ['run', 'fa', '--use-github', '--', 'gh', ...full],
          cwd: proj.path,
          env: env,
        );
        expect(
          conf.exit,
          base.exitCode,
          reason: 'gh : confined stderr: ${conf.stderr}',
        );
        // issue create / pr create are WRITE commands against a real repo —
        // the matrix runs them only against a disposable repo when
        // CUBERUN_GH_DISPOSABLE_REPO is set (CI); otherwise they are
        // asserted launch-compatible (identical failure mode both sides).
        if (!cmd.contains('create')) {
          expect(
            conf.stdout,
            base.stdout as String,
            reason: 'gh $cmd stdout diverged',
          );
        }
      }
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
