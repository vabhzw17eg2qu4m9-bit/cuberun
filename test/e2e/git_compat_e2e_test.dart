@Tags(['integration'])
library;

import 'dart:io';

import 'package:cube_sandbox/src/tool_catalog.dart';
import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// Confined profiles the matrix runs (AC12 requires `pi`/`fa`).
const kMatrixProfiles = ['fa', 'pi'];

/// AC12 — tool-compat matrix, git: EVERY verb in the pinned catalog
/// (incl. pull, push, clone over https) runs inside the `pi`/`fa`
/// profiles with `--use-github` against disposable fixture remotes with
/// IDENTICAL outcomes to the unconfined baseline — zero sandbox-induced
/// failures. E11 — an https private remote WITHOUT `--use-github` must
/// fail with an AUTH-class error, never a sandbox/file-denial one.
/// AC14 — the verb list is data from the pinned catalog: a suite entry
/// without a catalog scenario fails the guard below.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();
  late Directory tmpRoot;

  setUpAll(() {
    if (hostGuard == null) {
      tmpRoot = Directory.systemTemp.createTempSync('cube-sandbox-gitmx-');
      h.ensureBinary();
    }
  });
  tearDownAll(() {
    if (hostGuard == null) tmpRoot.deleteSync(recursive: true);
  });

  final scenarios = _buildScenarios();

  test('AC14: matrix covers exactly the pinned git catalog', () {
    expect(
      scenarios.keys.toSet(),
      kGitVerbs.toSet(),
      reason:
          'suite/catalog drift — extend the pinned catalog in a GOAL '
          'revision (E12)',
    );
  }, skip: false);

  for (final verb in kGitVerbs) {
    test(
      'git $verb: confined == unconfined (fa + pi)',
      () {
        final sc = scenarios[verb]!;
        final name = 'v-$verb';
        // Per-verb root: clones never collide across verbs.
        final froot = '${tmpRoot.path}/$name';
        final fixture = h.makeGitFixture(froot, name);
        // Second confined work repo: the pi leg shares no state with fa.
        final piRepo = '$froot/confined-pi';
        final piClone = _plainGit(['clone', fixture.remote, piRepo], froot);
        expect(
          piClone.exit,
          0,
          reason: 'pi-leg fixture clone failed: ${piClone.stderr}',
        );
        final remotePath = '$froot/$name.git';
        final seedDir = '$froot/$name-seed';
        sc.sharedPrep?.call(remotePath, seedDir);
        final repos = <String, String>{
          'baseline': fixture.baseline,
          'fa': fixture.confined,
          'pi': piRepo,
        };
        for (final repo in repos.values) {
          sc.prep?.call(repo);
        }

        final exits = <String, List<int>>{};
        final outs = <String, String>{};
        final stdouts = <String, String>{};
        for (final entry in repos.entries) {
          final side = entry.key;
          final repo = entry.value;
          final outBuf = StringBuffer();
          final stdoutBuf = StringBuffer();
          final exitList = <int>[];
          for (final batch in sc.batches) {
            final args = [
              for (final a in batch)
                a == 'CLONE_URL'
                    ? fixture.remote
                    : a == 'CLONE_TARGET'
                    ? '../${_base(repo)}-cloned'
                    : a == 'WTNAME'
                    ? 'wt' // in-repo: branch name must not derive from the side dir
                    : a,
            ];
            final r = side == 'baseline'
                ? _plainGit(args, repo)
                : _confinedGit(args, repo, side);
            exitList.add(r.exit);
            outBuf.write(r.stdout);
            outBuf.write(r.stderr);
            stdoutBuf.write(r.stdout);
          }
          exits[side] = exitList;
          outs[side] = outBuf.toString();
          stdouts[side] = stdoutBuf.toString();
        }

        for (final profile in kMatrixProfiles) {
          expect(
            exits[profile],
            exits['baseline'],
            reason: '[$profile] confined stderr: ${outs[profile]}',
          );
          String fpFor(String repo) => h.gitFingerprint(
            sc.cloneStyle ? _sibling(repo, '-cloned') : repo,
          );
          expect(
            fpFor(repos[profile]!),
            fpFor(repos['baseline']!),
            reason:
                '[$profile] post-verb fingerprints diverged '
                '(confined out: ${outs[profile]})',
          );
          if (sc.checkStdout) {
            // stdout ONLY: the confined launcher prints its grant banner on
            // stderr, which must not count as divergence.
            expect(
              h.normalizeOut(stdouts[profile]!, repos[profile]!),
              h.normalizeOut(stdouts['baseline']!, repos['baseline']!),
            );
          }
        }
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'real github.com leg: ls-remote over https matches baseline',
    () {
      final root = Directory.systemTemp.createTempSync('cube-sandbox-real-');
      addTearDown(() => root.deleteSync(recursive: true));
      const url = 'https://github.com/octocat/Hello-World.git';
      final base = _plainGit(['ls-remote', url], root.path);
      for (final profile in kMatrixProfiles) {
        final conf = _confinedGit(['ls-remote', url], root.path, profile);
        expect(
          conf.exit,
          base.exit,
          reason: '[$profile] confined stderr: ${conf.stderr}',
        );
        expect(conf.stdout, isNotEmpty);
      }
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'E11: https private remote without --use-github fails AUTH, not sandbox',
    () {
      final repo = _targetRepo();
      if (repo == null) {
        markTestSkipped(
          'no CUBE_SANDBOX_GH_TARGET_REPO/GITHUB_REPOSITORY and `gh repo view` '
          'resolved nothing — E11 needs a real private https remote',
        );
        return;
      }
      final vis = Process.runSync('gh', [
        'repo',
        'view',
        repo,
        '--json',
        'visibility',
        '-q',
        '.visibility',
      ]);
      if (vis.exitCode != 0) {
        markTestSkipped('gh repo view failed for $repo: ${vis.stderr}');
        return;
      }
      if ((vis.stdout as String).trim() != 'PRIVATE') {
        markTestSkipped(
          '$repo is not private — no unauthenticable https remote '
          'available for E11',
        );
        return;
      }
      final url = 'https://github.com/$repo.git';
      // Deterministic unauthenticable setup on BOTH sides: no credential
      // helper, no prompting, no global config — the only boundary the
      // clone can hit is the credential one, not a file-denial one.
      const e11Env = {
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_ASKPASS': '/usr/bin/false',
        'GIT_CONFIG_GLOBAL': '/dev/null',
      };
      const credOff = ['-c', 'credential.helper='];
      for (final profile in kMatrixProfiles) {
        final baseDir = '${tmpRoot.path}/e11-$profile-baseline';
        final confDir = '${tmpRoot.path}/e11-$profile-confined';
        final base = _plain(
          [...credOff, 'clone', url, baseDir],
          tmpRoot.path,
          e11Env,
        );
        final conf = h.launchCubeSandbox(
          ['launch', profile, '--', 'git', ...credOff, 'clone', url, confDir],
          cwd: tmpRoot.path,
          env: e11Env,
        );
        final baseErr = base.stderr;
        final confErr = _childStderr(conf.stderr);
        expect(
          base.exit,
          isNot(0),
          reason:
              'baseline clone succeeded — $repo is anonymously '
              'clonable, E11 needs a private remote: $baseErr',
        );
        expect(
          _authFailure.hasMatch(baseErr),
          isTrue,
          reason: 'baseline failure is not auth-class: $baseErr',
        );
        expect(conf.exit, base.exit, reason: '[$profile] stderr: $confErr');
        expect(
          _authFailure.hasMatch(confErr),
          isTrue,
          reason:
              '[$profile] E11 failure mode must classify AUTH, '
              'got: $confErr',
        );
        expect(
          _sandboxDenial.hasMatch(confErr),
          isFalse,
          reason:
              '[$profile] E11 failure looks sandbox/file-denial, '
              'not auth: $confErr',
        );
      }
    },
    skip: hostGuard ?? false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

// ---------------------------------------------------------------------------
// scenario table
// ---------------------------------------------------------------------------

/// Deterministic commit identity/dates for BOTH sides => identical shas
/// => fingerprints comparable across confined/baseline.
const Map<String, String> gitEnv = {
  'GIT_AUTHOR_NAME': 'cube-sandbox test',
  'GIT_AUTHOR_EMAIL': 'cube-sandbox@test.local',
  'GIT_COMMITTER_NAME': 'cube-sandbox test',
  'GIT_COMMITTER_EMAIL': 'cube-sandbox@test.local',
  'GIT_AUTHOR_DATE': '2005-04-07T22:13:13 +0000',
  'GIT_COMMITTER_DATE': '2005-04-07T22:13:13 +0000',
};

const ident = [
  '-c',
  'user.name=cube-sandbox test',
  '-c',
  'user.email=cube-sandbox@test.local',
];

/// One verb's scenario: argv batches run as `git <args>` in the repo dir,
/// plus optional per-side dart prep and one-time shared remote prep.
final class Scenario {
  Scenario(
    this.batches, {
    this.prep,
    this.sharedPrep,
    this.cloneStyle = false,
    this.checkStdout = false,
  });

  final List<List<String>> batches;
  final void Function(String repoDir)? prep;
  final void Function(String remotePath, String seedDir)? sharedPrep;

  /// Clone-shaped: target resolves to a sibling `<side>-cloned` dir.
  final bool cloneStyle;

  /// Stdout is deterministic after path normalization.
  final bool checkStdout;
}

void _commit(String repoDir) {
  Process.runSync(
    'git',
    [...ident, 'add', '.'],
    workingDirectory: repoDir,
    environment: gitEnv,
  );
  Process.runSync(
    'git',
    [...ident, 'commit', '-m', 'x'],
    workingDirectory: repoDir,
    environment: gitEnv,
  );
}

void _pushFeature(String remotePath, String seedDir) {
  Process.runSync(
    'git',
    [...ident, 'checkout', '-b', 'feature'],
    workingDirectory: seedDir,
    environment: gitEnv,
  );
  File('$seedDir/feature.txt').writeAsStringSync('feat\n');
  _commit(seedDir);
  Process.runSync(
    'git',
    [...ident, 'push', 'file://$remotePath', 'feature'],
    workingDirectory: seedDir,
    environment: gitEnv,
  );
  Process.runSync(
    'git',
    [...ident, 'checkout', 'main'],
    workingDirectory: seedDir,
    environment: gitEnv,
  );
}

Map<String, Scenario> _buildScenarios() => <String, Scenario>{
  'status': Scenario([
    ['status', '--porcelain=v1', '-b'],
  ], checkStdout: true),
  'log': Scenario([
    ['log', '--oneline'],
  ], checkStdout: true),
  'diff': Scenario(
    [
      ['diff'],
    ],
    prep: (d) => File('$d/src.txt').writeAsStringSync('v1\nCHANGED\nline3\n'),
    checkStdout: true,
  ),
  'show': Scenario([
    ['show', '--oneline', 'HEAD'],
  ], checkStdout: true),
  'branch': Scenario([
    ['branch', 'newbr'],
    ['branch'],
  ], checkStdout: true),
  'remote': Scenario([
    ['remote'],
  ], checkStdout: true),
  'add': Scenario([
    ['add', '.'],
  ], prep: (d) => File('$d/newfile.txt').writeAsStringSync('n\n')),
  'commit': Scenario(
    [
      [...ident, 'commit', '-m', 'matrix commit'],
    ],
    prep: (d) {
      File('$d/newfile.txt').writeAsStringSync('n\n');
      Process.runSync(
        'git',
        ['add', '.'],
        workingDirectory: d,
        environment: gitEnv,
      );
    },
  ),
  'push': Scenario(
    [
      [...ident, 'push', 'origin', 'HEAD:refs/heads/matrix-push'],
    ],
    prep: (d) {
      File('$d/push.txt').writeAsStringSync('p\n');
      _commit(d);
    },
  ),
  'pull': Scenario(
    [
      ['pull', '--no-edit', 'origin', 'main'],
    ],
    sharedPrep: (remote, seed) {
      File('$seed/pulled.txt').writeAsStringSync('pulled\n');
      _commit(seed);
      Process.runSync(
        'git',
        [...ident, 'push', 'file://$remote', 'main'],
        workingDirectory: seed,
        environment: gitEnv,
      );
    },
  ),
  'fetch': Scenario(
    [
      ['fetch', 'origin'],
    ],
    sharedPrep: (remote, seed) {
      File('$seed/fetched.txt').writeAsStringSync('f\n');
      _commit(seed);
      Process.runSync(
        'git',
        [...ident, 'push', 'file://$remote', 'main'],
        workingDirectory: seed,
        environment: gitEnv,
      );
    },
  ),
  'clone': Scenario([
    ['clone', 'CLONE_URL', 'CLONE_TARGET'],
  ], cloneStyle: true),
  'checkout': Scenario([
    ['checkout', '-b', 'ck'],
    ['checkout', 'main'],
  ]),
  'switch': Scenario([
    ['switch', '-c', 'sw'],
    ['switch', 'main'],
  ]),
  'restore': Scenario([
    ['restore', 'src.txt'],
  ], prep: (d) => File('$d/src.txt').writeAsStringSync('DIRTY\n')),
  'stash': Scenario([
    ['stash'],
    ['stash', 'list'],
  ], prep: (d) => File('$d/src.txt').writeAsStringSync('STASHED\n')),
  'tag': Scenario([
    ['tag', 'matrix-tag'],
    ['tag'],
  ], checkStdout: true),
  'merge': Scenario([
    ['merge', '--no-edit', 'origin/feature'],
  ], sharedPrep: _pushFeature),
  'rebase': Scenario(
    [
      ['rebase', 'origin/main'],
    ],
    prep: (d) {
      Process.runSync(
        'git',
        ['fetch', 'origin'],
        workingDirectory: d,
        environment: gitEnv,
      );
      Process.runSync(
        'git',
        ['checkout', '-B', 'rb', 'origin/feature'],
        workingDirectory: d,
        environment: gitEnv,
      );
      File('$d/rb.txt').writeAsStringSync('rb\n');
      _commit(d);
    },
  ),
  'rev-parse': Scenario([
    ['rev-parse', 'HEAD'],
  ], checkStdout: true),
  'config': Scenario([
    ['config', 'matrix.key', 'v'],
    ['config', '--get', 'matrix.key'],
  ], checkStdout: true),
  'ls-files': Scenario([
    ['ls-files'],
  ], checkStdout: true),
  'blame': Scenario([
    ['blame', 'src.txt'],
  ], checkStdout: true),
  'describe': Scenario([
    ['describe', '--tags'],
  ], checkStdout: true),
  'worktree': Scenario([
    ['worktree', 'add', 'WTNAME'],
  ]),
  'cherry-pick': Scenario(
    [
      ['cherry-pick', 'origin/feature'],
    ],
    prep: (d) {
      Process.runSync(
        'git',
        ['fetch', 'origin'],
        workingDirectory: d,
        environment: gitEnv,
      );
      Process.runSync(
        'git',
        ['checkout', '-B', 'cp'],
        workingDirectory: d,
        environment: gitEnv,
      );
    },
    sharedPrep: _pushFeature,
  ),
  'revert': Scenario([
    [...ident, 'revert', '--no-edit', 'HEAD'],
  ]),
  'clean': Scenario([
    ['clean', '-f'],
  ], prep: (d) => File('$d/untracked.txt').writeAsStringSync('u\n')),
  'apply': Scenario(
    [
      ['apply', 'p.patch'],
    ],
    prep: (d) => File('$d/p.patch').writeAsStringSync(
      'diff --git a/src.txt b/src.txt\n'
      'index 1234567..89abcde 100644\n'
      '--- a/src.txt\n+++ b/src.txt\n'
      '@@ -1,3 +1,3 @@\n v1\n-line2\n+LINE2\n line3\n',
    ),
  ),
  'rm': Scenario([
    ['rm', '-f', 'src.txt'],
  ]),
  'mv': Scenario([
    ['mv', 'src.txt', 'moved.txt'],
  ]),
  'rev-list': Scenario([
    ['rev-list', '--count', 'HEAD'],
  ], checkStdout: true),
  'ls-remote': Scenario([
    ['ls-remote', 'origin'],
  ], checkStdout: true),
};

String _base(String path) => path.split('/').last;
String _sibling(String repo, String suffix) {
  final i = repo.lastIndexOf('/');
  return '${repo.substring(0, i)}/${_base(repo)}$suffix';
}

h.RunOut _plainGit(List<String> args, String cwd) => _plain(args, cwd, gitEnv);

h.RunOut _plain(List<String> args, String cwd, Map<String, String> env) {
  final r = Process.runSync(
    'git',
    args,
    workingDirectory: cwd,
    environment: env,
  );
  return h.RunOut(r.exitCode, r.stdout as String, r.stderr as String);
}

h.RunOut _confinedGit(List<String> args, String cwd, String profile) {
  return h.launchCubeSandbox(
    ['launch', profile, '--use-github', '--', 'git', ...args],
    cwd: cwd,
    env: gitEnv,
  );
}

/// Strips the confined launcher banner (⛨ + indented lines) so only the
/// child's own stderr classifies.
String _childStderr(String stderr) => stderr
    .split('\n')
    .where((l) => !l.startsWith('⛨') && !l.startsWith(' '))
    .join('\n');

final _authFailure = RegExp(
  'could not read Username|Authentication failed|terminal prompts disabled|'
  '401|403',
);
final _sandboxDenial = RegExp('Operation not permitted|sandbox|file-read');

/// The cube-sandbox repo itself (E11 private remote): CUBE_SANDBOX_GH_TARGET_REPO >
/// GITHUB_REPOSITORY (CI) > `gh repo view` in the checkout (dart test
/// runs from the package root, which IS the repo). Null → loud skip.
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
