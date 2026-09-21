@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:cube_sandbox/src/tool_catalog.dart';
import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC12 — gh matrix: the pinned gh command surface runs inside the
/// `pi`/`fa` profiles with `--use-github` (token from the granted
/// `~/.config/gh` or GH_TOKEN env) with IDENTICAL outcomes to the
/// unconfined baseline. `issue create` / `pr create` run FOR REAL
/// against the cube-sandbox repo itself (scratch branch/issue titled
/// `cube-sandbox-matrix-<timestamp>`, closed/deleted in teardown even on
/// failure; target from CUBE_SANDBOX_GH_TARGET_REPO, default: this checkout
/// or GITHUB_REPOSITORY in CI — never a NEW repository). Skips with a
/// loud reason when gh, a token or a target repo is absent — never
/// silently green.

/// Confined profiles the matrix runs (AC12 requires `pi`/`fa`).
const _profiles = ['fa', 'pi'];

void main() {
  final hostGuard = h.nestedSandboxDeniedReason();

  test(
    'gh matrix: confined == unconfined for every cataloged command',
    () {
      final gh = Process.runSync('/usr/bin/which', ['gh']);
      if (gh.exitCode != 0) {
        markTestSkipped('gh binary not on PATH');
        return;
      }
      final token =
          Platform.environment['GH_TOKEN'] ??
          Platform.environment['GITHUB_TOKEN'];
      if (token == null || token.trim().isEmpty) {
        markTestSkipped(
          'no GH_TOKEN/GITHUB_TOKEN — AC12 gh leg skipped '
          'with reason, never silently green',
        );
        return;
      }

      final env = {'GH_TOKEN': token, 'GITHUB_TOKEN': token};
      final proj = Directory.systemTemp.createTempSync('cube-sandbox-ghmx-');
      addTearDown(() => proj.deleteSync(recursive: true));

      // create verbs are excluded here — they run FOR REAL in the two
      // dedicated tests below (scratch issue/branch in the cube-sandbox repo,
      // swept in teardown).
      for (final cmd in kGhCommands.where((c) => !c.contains('create'))) {
        final args = cmd.split(' ');
        // repo-scoped commands need a repo argument; use the public fixture
        // repo for reads — here: read surface + api.
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
        for (final profile in _profiles) {
          final conf = h.launchCubeSandbox(
            ['launch', profile, '--use-github', '--', 'gh', ...full],
            cwd: proj.path,
            env: env,
          );
          expect(
            conf.exit,
            base.exitCode,
            reason: '[$profile] gh $cmd: confined stderr: ${conf.stderr}',
          );
          expect(
            conf.stdout,
            base.stdout as String,
            reason: '[$profile] gh $cmd stdout diverged',
          );
        }
      }
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'gh issue create: confined == unconfined against the cube-sandbox repo',
    () {
      final g = _createGuards();
      if (g.skip != null) {
        markTestSkipped(g.skip!);
        return;
      }
      final env = <String, String>{
        'GH_TOKEN': g.token!,
        'GITHUB_TOKEN': g.token!,
      };
      final proj = Directory.systemTemp.createTempSync('cube-sandbox-ghissue-');
      addTearDown(() => proj.deleteSync(recursive: true));
      final title =
          'cube-sandbox-matrix-${DateTime.now().millisecondsSinceEpoch}';
      final args = [
        'issue',
        'create',
        '-R',
        g.repo!,
        '--title',
        title,
        '--body',
        'AC12 create-verb matrix artifact — disposable, '
            'closed in teardown',
      ];
      final created = <String>[];
      addTearDown(() => _sweepIssues(g.repo!, env, title, created));

      final base = Process.runSync(
        'gh',
        args,
        workingDirectory: proj.path,
        environment: env,
      );
      created.addAll(_issueNumbers(base.stdout as String));
      final conf = h.launchCubeSandbox(
        ['launch', 'fa', '--use-github', '--', 'gh', ...args],
        cwd: proj.path,
        env: env,
      );
      created.addAll(_issueNumbers(conf.stdout));

      expect(
        conf.exit,
        base.exitCode,
        reason: 'confined stderr: ${conf.stderr}',
      );
      expect(
        base.stdout,
        contains('/issues/'),
        reason:
            'unconfined create made no issue: '
            '${base.stdout}${base.stderr}',
      );
      expect(
        conf.stdout,
        contains('/issues/'),
        reason: 'confined create made no issue: ${conf.stdout}${conf.stderr}',
      );
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'gh pr create: confined == unconfined against the cube-sandbox repo',
    () {
      final g = _createGuards();
      if (g.skip != null) {
        markTestSkipped(g.skip!);
        return;
      }
      final repo = g.repo!;
      final env = <String, String>{
        'GH_TOKEN': g.token!,
        'GITHUB_TOKEN': g.token!,
      };
      final proj = Directory.systemTemp.createTempSync('cube-sandbox-ghpr-');
      addTearDown(() => proj.deleteSync(recursive: true));
      final title =
          'cube-sandbox-matrix-${DateTime.now().millisecondsSinceEpoch}';
      final branchBase = '$title-base';
      final branchConf = '$title-conf';
      final prs = <String>[];
      addTearDown(
        () => _sweepPrs(repo, env, title, prs, [branchBase, branchConf]),
      );

      // Scratch branch per side: ref off the default branch, then one file
      // commit so the PR has a diff. All harness-side (unconfined).
      final defBr = _gh(
        [
          'repo', 'view', repo, //
          '--json', 'defaultBranchRef', '-q', '.defaultBranchRef.name',
        ],
        env,
        'default branch lookup failed',
      );
      final sha = _gh(
        ['api', 'repos/$repo/git/ref/heads/$defBr', '-q', '.object.sha'],
        env,
        'head sha lookup failed',
      );
      void scratch(String branch, String side) {
        _gh(
          [
            'api',
            '-X',
            'POST',
            'repos/$repo/git/refs',
            '-f',
            'ref=refs/heads/$branch',
            '-f',
            'sha=$sha',
          ],
          env,
          'scratch branch $branch failed',
        );
        _gh(
          [
            'api',
            '-X',
            'PUT',
            'repos/$repo/contents/$title-$side.txt',
            '-f',
            'message=cube-sandbox matrix scratch',
            '-f',
            'content=${base64.encode(utf8.encode('cube-sandbox matrix scratch\n'))}',
            '-f',
            'branch=$branch',
          ],
          env,
          'scratch commit on $branch failed',
        );
      }

      scratch(branchBase, 'base');
      scratch(branchConf, 'conf');

      List<String> prArgs(String branch) => [
        'pr',
        'create',
        '-R',
        repo,
        '--head',
        branch,
        '--title',
        title,
        '--body',
        'AC12 create-verb matrix artifact — disposable, '
            'closed + branch deleted in teardown',
      ];
      final base = Process.runSync(
        'gh',
        prArgs(branchBase),
        workingDirectory: proj.path,
        environment: env,
      );
      prs.addAll(_prNumbers(base.stdout as String));

      // CI workflow tokens are frequently barred from creating PRs by
      // repo/org Actions policy. When the UNCONFINED baseline itself
      // fails with that capability error, confined==unconfined is
      // unanswerable here: skip LOUDLY (never silently green). Any other
      // baseline failure is a real failure and stays red.
      final baseOut = '${base.stdout}${base.stderr}';
      if (base.exitCode != 0 &&
          baseOut.contains(
            'GitHub Actions is not permitted to create or approve pull requests',
          )) {
        markTestSkipped(
          'workflow token cannot create PRs — repo Actions policy '
          '("GitHub Actions is not permitted to create or approve pull '
          'requests"); run locally with a PAT to exercise this leg',
        );
        return;
      }
      final conf = h.launchCubeSandbox(
        ['launch', 'fa', '--use-github', '--', 'gh', ...prArgs(branchConf)],
        cwd: proj.path,
        env: env,
      );
      prs.addAll(_prNumbers(conf.stdout));

      expect(
        conf.exit,
        base.exitCode,
        reason: 'confined stderr: ${conf.stderr}',
      );
      expect(
        base.stdout,
        contains('/pull/'),
        reason: 'unconfined create made no PR: ${base.stdout}${base.stderr}',
      );
      expect(
        conf.stdout,
        contains('/pull/'),
        reason: 'confined create made no PR: ${conf.stdout}${conf.stderr}',
      );
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// Guards for the real create-verb legs: (gh binary, token, target repo)
/// or a loud skip reason. Target is the cube-sandbox repo ITSELF — issues and
/// branches there are disposable; a NEW repository is never created
/// (workflow GITHUB_TOKEN cannot, and must not).
({String? skip, String? token, String? repo}) _createGuards() {
  final gh = Process.runSync('/usr/bin/which', ['gh']);
  if (gh.exitCode != 0) {
    return (skip: 'gh binary not on PATH', token: null, repo: null);
  }
  final token =
      Platform.environment['GH_TOKEN'] ?? Platform.environment['GITHUB_TOKEN'];
  if (token == null || token.trim().isEmpty) {
    return (
      skip:
          'no GH_TOKEN/GITHUB_TOKEN — AC12 create-verb leg skipped '
          'with reason, never silently green',
      token: null,
      repo: null,
    );
  }
  final repo = _targetRepo();
  if (repo == null) {
    return (
      skip:
          'no CUBE_SANDBOX_GH_TARGET_REPO/GITHUB_REPOSITORY and `gh repo view` '
          'resolved nothing — create-verb leg skipped loudly',
      token: null,
      repo: null,
    );
  }
  return (skip: null, token: token, repo: repo);
}

/// AC12(b)/E11 target repo: CUBE_SANDBOX_GH_TARGET_REPO > GITHUB_REPOSITORY
/// (CI) > `gh repo view` in the checkout (dart test runs from the
/// package root, which IS the repo).
String? _targetRepo() {
  final direct =
      Platform.environment['CUBE_SANDBOX_GH_TARGET_REPO'] ??
      Platform.environment['GITHUB_REPOSITORY'];
  if (direct != null && direct.trim().isNotEmpty) return direct.trim();
  final r = Process.runSync('gh', const [
    'repo',
    'view',
    '--json',
    'nameWithOwner',
    '-q',
    '.nameWithOwner',
  ], workingDirectory: Directory.current.path);
  if (r.exitCode != 0) return null;
  final s = (r.stdout as String).trim();
  return s.isEmpty ? null : s;
}

/// Harness-side gh setup step; `fail` (red, not silent) on error.
String _gh(List<String> args, Map<String, String> env, String why) {
  final r = Process.runSync('gh', args, environment: env);
  if (r.exitCode != 0) {
    fail('$why: ${r.stderr}');
  }
  return (r.stdout as String).trim();
}

final _issueNo = RegExp(r'/issues/(\d+)');
final _prNo = RegExp(r'/pull/(\d+)');

List<String> _issueNumbers(String stdout) =>
    _issueNo.allMatches(stdout).map((m) => m.group(1)!).toList();
List<String> _prNumbers(String stdout) =>
    _prNo.allMatches(stdout).map((m) => m.group(1)!).toList();

/// Teardown: close parsed numbers, then sweep by title so a half-failed
/// run still leaves nothing behind. Best-effort — never throws.
void _sweepIssues(
  String repo,
  Map<String, String> env,
  String title,
  List<String> numbers,
) {
  for (final n in {...numbers, ..._byTitle(repo, env, title, 'issue')}) {
    Process.runSync('gh', ['issue', 'close', n, '-R', repo], environment: env);
  }
}

void _sweepPrs(
  String repo,
  Map<String, String> env,
  String title,
  List<String> numbers,
  List<String> branches,
) {
  for (final n in {...numbers, ..._byTitle(repo, env, title, 'pr')}) {
    Process.runSync('gh', ['pr', 'close', n, '-R', repo], environment: env);
  }
  for (final b in branches) {
    Process.runSync('gh', [
      'api',
      '-X',
      'DELETE',
      'repos/$repo/git/refs/heads/$b',
    ], environment: env);
  }
}

Set<String> _byTitle(
  String repo,
  Map<String, String> env,
  String title,
  String kind,
) {
  final r = Process.runSync('gh', [
    kind,
    'list',
    '-R',
    repo,
    '--state',
    'all',
    '--search',
    'in:title $title',
    '--json',
    'number',
    '-q',
    '.[].number',
  ], environment: env);
  return (r.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toSet();
}
