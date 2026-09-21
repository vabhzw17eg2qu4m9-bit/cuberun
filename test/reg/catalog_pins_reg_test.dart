import 'package:cube_sandbox/src/service_grants.dart';
import 'package:cube_sandbox/src/tool_catalog.dart';
import 'package:test/test.dart';

/// REG — the catalogs are PINNED: a folder list change (service grants)
/// or a verb list change (tool matrix) without a GOAL revision is a red
/// build (E12, AC14).
void main() {
  test('service-grant catalog pinned (id -> folders)', () {
    // Format: one 'id|read...|write...' pin per catalog entry, in order.
    final pins = [
      'github|~/.config/gh,~/.gitconfig|',
      'gitlab|~/.config/glab,~/.gitconfig|',
      'nvm|~/.nvm|',
    ];
    final actual = [
      for (final g in kServiceCatalog)
        '${g.id}|${g.read.join(',')}|${g.write.join(',')}',
    ];
    expect(actual, pins);
  });

  test('tool-verb catalog pinned: git verbs', () {
    expect(kGitVerbs, const <String>[
      'status', 'log', 'diff', 'show', 'branch', 'remote', //
      'add', 'commit', 'push', 'pull', 'fetch', 'clone', //
      'checkout', 'switch', 'restore', 'stash', 'tag', 'merge', //
      'rebase', 'rev-parse', 'config', 'ls-files', 'blame', 'describe', //
      'worktree', 'cherry-pick', 'revert', 'clean', 'apply', 'rm', //
      'mv', 'rev-list', 'ls-remote',
    ]);
    expect(kGitVerbs.length, 33);
    expect(kGitVerbs.toSet().length, kGitVerbs.length, reason: 'no dup verbs');
  });

  test('tool-verb catalog pinned: gh commands', () {
    expect(kGhCommands, const <String>[
      'auth status', //
      'api user', //
      'repo view', //
      'issue list', 'issue view', 'issue create', //
      'pr list', 'pr view', 'pr create', //
      'release list', 'release view',
    ]);
  });

  test('ungrantable suffix list pinned (E10)', () {
    expect(kUngrantableHomeSuffixes, ['.ssh', '.gnupg', 'Library/Keychains']);
  });
}
