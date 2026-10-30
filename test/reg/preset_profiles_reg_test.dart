import 'package:cube_sandbox/src/presets.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:test/test.dart';

/// REG — the SBPL text of all five presets is asserted against pinned
/// expectations (deny roots, metadata re-allows, grant lines, key10):
/// a diff in preset confinement is a RED build even when all behavior
/// tests stay green.
void main() {
  // FIXED machine facts => deterministic profiles => pinnable keys.
  HarnessRuntime fixed(
    String agentRoot, {
    List<String> extraRead = const [],
    List<String> extraWrite = const [],
    List<String> extraWritePrefix = const [],
  }) => HarnessRuntime(
    projDir: '/Users/dev/proj',
    agentRoot: agentRoot,
    tmp: '/private/var/folders/ab/T123',
    extraRead: extraRead,
    extraWrite: extraWrite,
    extraWritePrefix: extraWritePrefix,
    runtimeDirs: const [],
  );

  final runtimes = <String, HarnessRuntime>{
    'claude': fixed(
      '/Users/dev/.claude',
      extraWritePrefix: const ['/Users/dev/.claude.json'],
    ),
    'claude-desktop': fixed(
      '/Users/dev/Library/Application Support/Claude',
      extraWrite: const [
        '/Users/dev/Library/Logs/Claude',
        '/Users/dev/Library/Caches/com.anthropic.claude',
      ],
    ),
    'fa': fixed('/Users/dev/.fah'),
    'omp': fixed('/Users/dev/.omp'),
    'pi': fixed('/Users/dev/.pi'),
  };
  final profiles = <String, SbplProfile>{
    for (final e in runtimes.entries) e.key: emitProfile(e.value),
  };

  final claude = profiles['claude']!;
  final claudeDesktop = profiles['claude-desktop']!;
  final fa = profiles['fa']!;
  final omp = profiles['omp']!;
  final pi = profiles['pi']!;

  test('all five presets parse and emit', () {
    expect(HarnessPresets.ids, ['claude', 'claude-desktop', 'fa', 'omp', 'pi']);
    expect(claude.text.isNotEmpty, isTrue);
    expect(claudeDesktop.text.isNotEmpty, isTrue);
    expect(fa.text.isNotEmpty, isTrue);
    expect(omp.text.isNotEmpty, isTrue);
    expect(pi.text.isNotEmpty, isTrue);
  });

  test('AC-C5: preset catalog + per-preset grant lists pinned', () {
    // Format: id|command|agentRoot|agentRootEnv|extraWrite|extraWritePrefix,
    // in id order. #140: claude-desktop command is a fixed argv list
    // (command.first pins argv0; the --no-sandbox tail is a UT pin).
    final pins = [
      'claude|claude|~/.claude|CLAUDE_CONFIG_DIR||'
          '~/.claude.json',
      'claude-desktop|/Applications/Claude.app/Contents/MacOS/Claude|'
          '~/Library/Application Support/Claude||'
          '~/Library/Logs/Claude,~/Library/Caches/com.anthropic.claude|',
      'fa|fa|~/.fah|||',
      'omp|omp|~/.omp|OMP_AGENT_DIR||',
      'pi|pi|~/.pi/agent|PI_CODING_AGENT_DIR||',
    ];
    final actual = [
      for (final e in HarnessPresets.loadAll().entries)
        '${e.key}|${e.value.command.first}|${e.value.agentRoot}'
            '|${e.value.agentRootEnv ?? ''}|${e.value.extraWrite.join(',')}'
            '|${e.value.extraWritePrefix.join(',')}',
    ];
    expect(actual, pins);
  });

  test('key10 pins (confinement drift detector)', () {
    // These literals ARE the regression pins: any change to profile
    // semantics for the same facts turns this red. #140 note: the
    // claude-desktop --no-sandbox argv is NOT a profile input — its
    // key10 is unchanged by the fix.
    expect(claude.key10, 'b5cf00da3c');
    expect(claudeDesktop.key10, '46d20a8ae9');
    expect(fa.key10, 'e8ee06804e');
    expect(omp.key10, 'a969c70e85');
    expect(pi.key10, 'c3f35f98a1');
  });

  test('identical facts => identical text, always', () {
    expect(
      emitProfile(
        fixed(
          '/Users/dev/.claude',
          extraWritePrefix: const ['/Users/dev/.claude.json'],
        ),
      ).text,
      claude.text,
    );
    expect(
      emitProfile(
        fixed(
          '/Users/dev/Library/Application Support/Claude',
          extraWrite: const [
            '/Users/dev/Library/Logs/Claude',
            '/Users/dev/Library/Caches/com.anthropic.claude',
          ],
        ),
      ).text,
      claudeDesktop.text,
    );
    expect(emitProfile(fixed('/Users/dev/.fah')).text, fa.text);
    expect(emitProfile(fixed('/Users/dev/.omp')).text, omp.text);
    expect(emitProfile(fixed('/Users/dev/.pi')).text, pi.text);
  });

  for (final entry in profiles.entries) {
    group('REG structural pins: ${entry.key}', () {
      final rt = runtimes[entry.key]!;
      final text = entry.value.text;

      test('header pinned (version/default/open network)', () {
        expect(text.split('\n').take(3), [
          '(version 1)',
          '(allow default)',
          '(allow network*)',
        ]);
        expect(text, isNot(contains('(deny network')));
      });

      test('deny roots pinned, both spellings, metadata re-allows', () {
        for (final root in kReadDenyRoots) {
          expect(text, contains('(deny file-read* (subpath "$root"))'));
          expect(
            text,
            contains('(allow file-read-metadata (subpath "$root"))'),
          );
        }
        expect(text, contains('(deny file-read* (subpath "/Users"))'));
        expect(text, contains('(deny file-read* (subpath "/private/Users"))'));
        expect(text, contains('(deny file-read* (subpath "/var"))'));
        expect(text, contains('(deny file-read* (subpath "/private/var"))'));
      });

      test('NO blanket read deny (E1: unbuildable — compiler aborts)', () {
        expect(text, isNot(contains('(deny file-read*)')));
      });

      test('system re-allows under /private/var pinned', () {
        expect(
          text,
          contains('(allow file-read* (subpath "/private/var/db/dyld"))'),
        );
        expect(
          text,
          contains('(allow file-read* (subpath "/private/var/run"))'),
        );
      });

      test('writes: bare deny + /dev/null + /dev/fd + rw roots only', () {
        expect(text, contains('(deny file-write*)'));
        expect(text, contains('(allow file-write* (literal "/dev/null"))'));
        expect(text, contains('(allow file-write* (subpath "/dev/fd"))'));
        expect(
          text,
          contains('(allow file-write* (subpath "/Users/dev/proj"))'),
        );
        expect(
          text,
          contains(
            '(allow file-write* (subpath "/private/var/folders/ab/T123"))',
          ),
        );
        final ownWrites = [
          '/dev/',
          '/Users/dev/proj',
          '/private/var/folders/ab/T123',
          ...rt.extraWrite,
          ...rt.extraWritePrefix,
        ];
        final foreignWriteAllows = text
            .split('\n')
            .where((l) => l.startsWith('(allow file-write*'))
            .where((l) => !ownWrites.any(l.contains));
        expect(
          foreignWriteAllows,
          isEmpty,
          reason: 'no write allows outside the rw roots',
        );
      });

      test('no secret-ish tokens in text', () {
        expect(text, isNot(contains('ghp_')));
        expect(text, isNot(contains('sk-ant-')));
        expect(text, isNot(contains('BEGIN OPENSSH PRIVATE KEY')));
      });
    });
  }

  test('REG: claude grants the ~/.claude.json sibling family by prefix '
      '(issue #139)', () {
    // The exact file AND its atomic-write siblings ride ONE prefix rule;
    // both spellings re-allowed for reads with the same scope.
    expect(
      claude.text,
      contains('(allow file-write* (prefix "/Users/dev/.claude.json"))'),
    );
    expect(
      claude.text,
      contains('(allow file-read* (prefix "/Users/dev/.claude.json"))'),
    );
    expect(
      claude.text,
      contains('(allow file-read* (prefix "/private/Users/dev/.claude.json"))'),
    );
    // The old literal for the .backup sibling is gone — covered by the
    // prefix (its string-prefix sibling family), never a separate rule.
    expect(claude.text, isNot(contains('.claude.json.backup')));
  });
}
