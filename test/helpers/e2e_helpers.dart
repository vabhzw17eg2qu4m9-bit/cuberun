/// Shared E2E helpers: host guards, compiled-binary driver, git fixtures.
library;

import 'dart:io';

/// Why a suite cannot run on this host right now (never silent).
String? nestedSandboxDeniedReason() {
  final tmpDir = Directory.systemTemp.createTempSync('cuberun-guard-');
  try {
    final sb = File('${tmpDir.path}/guard.sb');
    sb.writeAsStringSync('(version 1)\n(allow default)\n(deny file-write*)\n');
    final r = Process.runSync('/usr/bin/sandbox-exec', [
      '-f',
      sb.path,
      '/usr/bin/true',
    ]);
    if (r.exitCode != 0) {
      final err = (r.stderr as String).trim();
      if (err.contains('sandbox_apply') ||
          err.contains('Operation not permitted')) {
        return 'host denies nested profile application (agent dev cube): '
            '$err';
      }
      return 'sandbox-exec cannot apply a denying profile here: $err';
    }
    return null;
  } finally {
    tmpDir.deleteSync(recursive: true);
  }
}

/// Builds the cuberun binary once per suite run; returns its path.
String ensureBinary() {
  final exe = '.cache/cuberun-e2e';
  if (!File(exe).existsSync()) {
    final r = Process.runSync('dart', [
      'compile',
      'exe',
      'bin/cuberun.dart',
      '-o',
      exe,
    ]);
    if (r.exitCode != 0) {
      throw StateError('dart compile failed: ${r.stderr}');
    }
  }
  return exe;
}

/// One cuberun invocation; returns (exit, stdout, stderr).
class RunOut {
  RunOut(this.exit, this.stdout, this.stderr);
  final int exit;
  final String stdout;
  final String stderr;
}

RunOut runCuberun(List<String> args, {String? cwd, Map<String, String>? env}) {
  final exe = ensureBinary();
  final r = Process.runSync(
    exe,
    args,
    workingDirectory: cwd,
    environment: {...?env, 'CUBERUN_E2E': '1'},
  );
  return RunOut(r.exitCode, r.stdout as String, r.stderr as String);
}

/// Whether a provider env exists for live harness runs (AC13/AC15 skip
/// guard — NEVER silently green).
bool providerEnvPresent() {
  const keys = [
    'ANTHROPIC_API_KEY',
    'OPENAI_API_KEY',
    'GEMINI_API_KEY',
    'GOOGLE_API_KEY',
    'GROQ_API_KEY',
    'OPENROUTER_API_KEY',
    'CUBERUN_FORCE_PROVIDER_ENV',
  ];
  return Platform.environment.keys
      .toSet()
      .intersection(keys.toSet())
      .isNotEmpty;
}

/// Deterministic commit identity/dates (shared with the git matrix).
const Map<String, String> gitEnv = {
  'GIT_AUTHOR_NAME': 'cuberun test',
  'GIT_AUTHOR_EMAIL': 'cuberun@test.local',
  'GIT_COMMITTER_NAME': 'cuberun test',
  'GIT_COMMITTER_EMAIL': 'cuberun@test.local',
  'GIT_AUTHOR_DATE': '2005-04-07T22:13:13 +0000',
  'GIT_COMMITTER_DATE': '2005-04-07T22:13:13 +0000',
};

/// A disposable git fixture: a bare remote seeded deterministically plus
/// helper clones.
class GitFixture {
  GitFixture(this.root, this.remote)
    : baseline = '$root/baseline',
      confined = '$root/confined';

  final String root;
  final String remote; // bare repo path (file:// URL ready)
  final String baseline;
  final String confined;
}

/// Creates the fixture: bare remote with a seeded commit (fixed identity,
/// fixed tree), plus two clones (baseline + confined).
GitFixture makeGitFixture(String root, String name) {
  final remote = '$root/$name.git';
  Process.runSync('git', ['init', '--bare', '--initial-branch=main', remote]);
  final seed = '$root/$name-seed';
  Directory(seed).createSync(recursive: true);
  const ident = [
    '-c',
    'user.name=cuberun test',
    '-c',
    'user.email=cuberun@test.local',
  ];
  void git(List<String> args, [String? cwd]) => Process.runSync(
    'git',
    args,
    workingDirectory: cwd ?? seed,
    environment: const {
      'GIT_AUTHOR_NAME': 'cuberun test',
      'GIT_AUTHOR_EMAIL': 'cuberun@test.local',
      'GIT_COMMITTER_NAME': 'cuberun test',
      'GIT_COMMITTER_EMAIL': 'cuberun@test.local',
      'GIT_AUTHOR_DATE': '2005-04-07T22:13:13 +0000',
      'GIT_COMMITTER_DATE': '2005-04-07T22:13:13 +0000',
    },
  );
  git(['init', '--initial-branch=main']);
  File('$seed/README.md').writeAsStringSync('fixture $name\n');
  File('$seed/src.txt').writeAsStringSync('v1\nline2\nline3\n');
  git([...ident, 'add', '.']);
  git([...ident, 'commit', '-m', 'seed commit']);
  git([...ident, 'tag', 'v1']);
  git([...ident, 'remote', 'add', 'origin', 'file://$remote']);
  git([...ident, 'push', 'origin', 'main', '--tags']);
  Process.runSync('git', ['clone', 'file://$remote', '$root/baseline']);
  Process.runSync('git', ['clone', 'file://$remote', '$root/confined']);
  return GitFixture(root, 'file://$remote');
}

/// State fingerprint of a work repo for confined-vs-baseline equality.
String gitFingerprint(String dir) {
  String run(List<String> args) {
    final r = Process.runSync('git', args, workingDirectory: dir);
    return (r.stdout as String).trim();
  }

  return [
    run(['status', '--porcelain']),
    run(['rev-parse', 'HEAD']),
    run(['for-each-ref', '--format=%(refname)', 'refs/heads', 'refs/tags']),
    run(['stash', 'list']),
  ].join('||');
}

/// Normalizes a side's absolute path out of command output.
String normalizeOut(String s, String dir) => s.replaceAll(dir, 'REPO');
