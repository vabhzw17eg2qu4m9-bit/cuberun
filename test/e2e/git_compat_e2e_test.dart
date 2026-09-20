@Tags(['integration'])
library;

import 'dart:io';

import 'package:cuberun/src/tool_catalog.dart';
import 'package:test/test.dart';

import '../helpers/e2e_helpers.dart' as h;

/// AC12 — tool-compat matrix, git: EVERY verb in the pinned catalog
/// (incl. pull, push, clone over https) runs inside the `fa` profile with
/// `--use-github` against disposable fixture remotes with IDENTICAL
/// outcomes to the unconfined baseline — zero sandbox-induced failures.
/// AC14 — the verb list is data from the pinned catalog: a suite entry
/// without a catalog scenario fails the guard below.
void main() {
  final hostGuard = h.nestedSandboxDeniedReason();
  late Directory tmpRoot;

  setUpAll(() {
    if (hostGuard == null) {
      tmpRoot = Directory.systemTemp.createTempSync('cuberun-gitmx-');
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
      'git $verb: confined == unconfined',
      () {
        final sc = scenarios[verb]!;
        final name = 'v-$verb';
        final fixture = h.makeGitFixture(tmpRoot.path, name);
        final remotePath = '${tmpRoot.path}/$name.git';
        final seedDir = '${tmpRoot.path}/$name-seed';
        sc.sharedPrep?.call(remotePath, seedDir);
        for (final side in [fixture.baseline, fixture.confined]) {
          sc.prep?.call(side);
        }

        final exits = <String, List<int>>{};
        final outs = <String, String>{};
        for (final entry in {
          'baseline': fixture.baseline,
          'confined': fixture.confined,
        }.entries) {
          final side = entry.key;
          final repo = entry.value;
          final workDir = repo;
          final outBuf = StringBuffer();
          final exitList = <int>[];
          for (final batch in sc.batches) {
            final args = [
              for (final a in batch)
                a == 'CLONE_URL'
                    ? fixture.remote
                    : a == 'CLONE_TARGET'
                    ? '../${_base(repo)}-cloned'
                    : a == 'WTNAME'
                    ? '../${_base(repo)}-wt'
                    : a,
            ];
            final r = side == 'baseline'
                ? _plainGit(args, workDir)
                : _confinedGit(args, workDir);
            exitList.add(r.exit);
            outBuf.write(r.stdout);
            outBuf.write(r.stderr);
          }
          exits[side] = exitList;
          outs[side] = outBuf.toString();
        }

        expect(
          exits['confined'],
          exits['baseline'],
          reason: 'confined stderr: ${outs['confined']}',
        );
        String fpFor(String repo) =>
            h.gitFingerprint(sc.cloneStyle ? _sibling(repo, '-cloned') : repo);
        expect(
          fpFor(fixture.confined),
          fpFor(fixture.baseline),
          reason:
              'post-verb fingerprints diverged '
              '(confined out: ${outs['confined']})',
        );
        if (sc.checkStdout) {
          expect(
            h.normalizeOut(outs['confined']!, fixture.confined),
            h.normalizeOut(outs['baseline']!, fixture.baseline),
          );
        }
      },
      skip: hostGuard ?? false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }

  test(
    'real github.com leg: ls-remote over https matches baseline',
    () {
      final root = Directory.systemTemp.createTempSync('cuberun-real-');
      addTearDown(() => root.deleteSync(recursive: true));
      const url = 'https://github.com/octocat/Hello-World.git';
      final base = _plainGit(['ls-remote', url], root.path);
      final conf = _confinedGit(['ls-remote', url], root.path);
      expect(conf.exit, base.exit, reason: 'confined stderr: ${conf.stderr}');
      expect(conf.stdout, isNotEmpty);
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
  'GIT_AUTHOR_NAME': 'cuberun test',
  'GIT_AUTHOR_EMAIL': 'cuberun@test.local',
  'GIT_COMMITTER_NAME': 'cuberun test',
  'GIT_COMMITTER_EMAIL': 'cuberun@test.local',
  'GIT_AUTHOR_DATE': '2005-04-07T22:13:13 +0000',
  'GIT_COMMITTER_DATE': '2005-04-07T22:13:13 +0000',
};

const ident = [
  '-c',
  'user.name=cuberun test',
  '-c',
  'user.email=cuberun@test.local',
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

h.RunOut _plainGit(List<String> args, String cwd) {
  final r = Process.runSync(
    'git',
    args,
    workingDirectory: cwd,
    environment: gitEnv,
  );
  return h.RunOut(r.exitCode, r.stdout as String, r.stderr as String);
}

h.RunOut _confinedGit(List<String> args, String cwd) {
  return h.runCuberun(
    ['run', 'fa', '--use-github', '--', 'git', ...args],
    cwd: cwd,
    env: gitEnv,
  );
}
