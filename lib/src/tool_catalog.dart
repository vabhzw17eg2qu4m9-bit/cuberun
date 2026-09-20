/// The pinned tool-verb catalog: the per-tool command inventories the
/// tool-compat matrix runs (AC14). The lists are DATA — adding a verb to
/// the suite without extending the catalog fails the REG guard, and a
/// catalog change without a GOAL revision is a red build (E12).
library;

/// Every git verb the confined matrix exercises (GOAL core tier,
/// verbatim order): each runs inside the profile with `--use-github`
/// against disposable fixture remotes (+ real github.com in CI) and must
/// have IDENTICAL outcomes to the unconfined baseline (AC12).
const List<String> kGitVerbs = <String>[
  'status', 'log', 'diff', 'show', 'branch', 'remote', //
  'add', 'commit', 'push', 'pull', 'fetch', 'clone', //
  'checkout', 'switch', 'restore', 'stash', 'tag', 'merge', //
  'rebase', 'rev-parse', 'config', 'ls-files', 'blame', 'describe', //
  'worktree', 'cherry-pick', 'revert', 'clean', 'apply', 'rm', //
  'mv', 'rev-list', 'ls-remote',
];

/// gh command surface covered by the matrix (AC12): token from the
/// granted `~/.config/gh`, no Keychain.
const List<String> kGhCommands = <String>[
  'auth status', //
  'api user', //
  'repo view', //
  'issue list', 'issue view', 'issue create', //
  'pr list', 'pr view', 'pr create', //
  'release list', 'release view',
];
