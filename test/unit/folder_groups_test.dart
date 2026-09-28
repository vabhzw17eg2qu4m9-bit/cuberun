import 'package:cube_sandbox/src/banner.dart';
import 'package:cube_sandbox/src/cache_policy.dart';
import 'package:cube_sandbox/src/exceptions.dart';
import 'package:cube_sandbox/src/folder_groups.dart';
import 'package:cube_sandbox/src/harness_manifest.dart';
import 'package:cube_sandbox/src/resolver.dart';
import 'package:cube_sandbox/src/runtime.dart';
import 'package:cube_sandbox/src/sbpl.dart';
import 'package:cube_sandbox/src/service_grants.dart';
import 'package:test/test.dart';

/// UT for folder groups (issue #101): strict parse of the ONE user-level
/// groups file, argv token selection, per-direction blocklist, the pinned
/// merge order, emit/key10 sensitivity, and banner truthfulness. Pure
/// module — importable without cli.dart (PF15).
void main() {
  const home = '/Users/dev';
  const filePath = '$home/.cube-sandbox/folders.yaml';

  final doc = parseFolderGroups(
    '''
apiVersion: cube-sandbox/v1
groups:
  projecta:
    write: [~/work/projecta]
  projectb:
    write: [~/work/projectb, /Volumes/data/projB]
    read: [~/Library/Caches/big-model]
''',
    path: filePath,
    home: home,
  );

  HarnessRuntime rt({
    List<String> read = const [],
    List<String> write = const [],
    List<String> warnings = const [],
  }) => resolveRuntime(
    const HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
    services: const {},
    cwd: '/w',
    home: home,
    env: const {'TMPDIR': '/private/var/folders/t/T1'},
    fs: _NoIO(),
    folderRead: read,
    folderWrite: write,
  ).withGrants(warnings: warnings);

  group('UT-1 strict parse (AC1)', () {
    test(
      'documented example: typed groups, tilde entries expanded absolute',
      () {
        expect(doc.groups.keys, ['projecta', 'projectb']);
        expect(doc.groups['projecta']!.write, ['$home/work/projecta']);
        expect(doc.groups['projecta']!.read, isEmpty);
        expect(doc.groups['projectb']!.write, [
          '$home/work/projectb',
          '/Volumes/data/projB',
        ]);
        expect(doc.groups['projectb']!.read, [
          '$home/Library/Caches/big-model',
        ]);
      },
    );

    test('absent groups: valid no-op', () {
      final d = parseFolderGroups(
        'apiVersion: cube-sandbox/v1\n',
        path: filePath,
        home: home,
      );
      expect(d.groups, isEmpty);
    });

    test('empty groups map: valid no-op', () {
      for (final text in [
        'apiVersion: cube-sandbox/v1\ngroups:\n',
        'apiVersion: cube-sandbox/v1\ngroups: {}\n',
      ]) {
        final d = parseFolderGroups(text, path: filePath, home: home);
        expect(d.groups, isEmpty);
      }
    });
  });

  group('UT-2 parse negatives (AC2)', () {
    void bad(String text, {required Matcher matches}) {
      expect(
        () => parseFolderGroups(text, path: filePath, home: home),
        throwsA(
          isA<ConfigException>().having((e) => e.message, 'message', matches),
        ),
        reason: text,
      );
    }

    test('unknown top-level key', () {
      bad(
        'apiVersion: cube-sandbox/v1\nbogus: 1\n',
        matches: contains('bogus: unknown key'),
      );
    });

    test('manifest-only keys rejected in the groups file', () {
      bad(
        'apiVersion: cube-sandbox/v1\ncommand: ls\n',
        matches: contains('command: unknown key'),
      );
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    agentRoot: ~/.x\n',
        matches: contains('groups.g.agentRoot: unknown key'),
      );
    });

    test('groups not a map', () {
      bad(
        'apiVersion: cube-sandbox/v1\ngroups: [a]\n',
        matches: contains('groups: must be a map'),
      );
    });

    test('group body not a map', () {
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g: 7\n',
        matches: contains('groups.g: must be a map'),
      );
    });

    test('per-group unknown key', () {
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    reads: [/x]\n',
        matches: contains('groups.g.reads: unknown key'),
      );
    });

    test('wrong value type / non-string entry', () {
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    read: ~/.x\n',
        matches: contains('groups.g.read: must be a list of paths'),
      );
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    read: [7]\n',
        matches: contains('groups.g.read[0]: must be a path string'),
      );
    });

    test('charset-violating group name', () {
      bad(
        'apiVersion: cube-sandbox/v1\ngroups:\n  BadName:\n    read: [/x]\n',
        matches: contains('group name must match [a-z0-9][a-z0-9-]*'),
      );
    });

    test('missing / wrong apiVersion', () {
      bad('groups: {}\n', matches: contains('apiVersion'));
      bad(
        'apiVersion: cube-sandbox/v2\ngroups: {}\n',
        matches: contains('apiVersion: must be "cube-sandbox/v1"'),
      );
    });

    test('empty document and malformed yaml', () {
      bad('', matches: contains('empty document'));
      bad('apiVersion: [oops\n', matches: contains('invalid yaml'));
    });

    test('every negative names the file', () {
      final texts = [
        'apiVersion: cube-sandbox/v1\nbogus: 1\n',
        'apiVersion: cube-sandbox/v2\n',
        'groups: 3\n',
      ];
      for (final t in texts) {
        try {
          parseFolderGroups(t, path: filePath, home: home);
          fail('expected ConfigException for $t');
        } on ConfigException catch (e) {
          expect(e.message, contains(filePath));
        }
      }
    });
  });

  group('UT-4 token parser (AC4, AC12)', () {
    test('comma split + repeatable accumulation, order preserved', () {
      expect(parseFolderSelection(const []), isEmpty);
      expect(parseFolderSelection(['a']), ['a']);
      expect(parseFolderSelection(['a,b']), ['a', 'b']);
      expect(parseFolderSelection(['a', 'b', 'a,c']), ['a', 'b', 'c']);
    });

    test('malformed shapes are usage errors', () {
      for (final t in ['', 'a,', ',a', 'a,,b', 'a, b', 'A', 'a_b', '-x']) {
        expect(
          () => parseFolderSelection([t]),
          throwsA(isA<UsageException>()),
          reason: 'token "$t" must be a usage error',
        );
      }
    });
  });

  group('selection + union (AC4, E1, E6, E7)', () {
    test('unknown group: ConfigException naming group AND file', () {
      expect(
        () => resolveFolderGroups(doc, ['nope'], home: home),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('nope'), contains('folders.yaml')),
          ),
        ),
      );
    });

    test('union per direction; same path in two groups appears once (E7)', () {
      final d = parseFolderGroups(
        'apiVersion: cube-sandbox/v1\ngroups:\n'
        '  g1:\n    write: [/shared, /g1]\n    read: [/r1]\n'
        '  g2:\n    write: [/shared, /g2]\n',
        path: filePath,
        home: home,
      );
      final s = resolveFolderGroups(d, ['g1', 'g2'], home: home);
      expect(s.write, ['/shared', '/g1', '/g2']);
      expect(s.read, ['/r1']);
    });

    test('duplicate selection names union once (E6)', () {
      final s = resolveFolderGroups(
        doc,
        parseFolderSelection(['projecta', 'projecta,projectb']),
        home: home,
      );
      expect(s.groups.map((g) => g.name), ['projecta', 'projectb']);
      expect(s.write, [
        '$home/work/projecta',
        '$home/work/projectb',
        '/Volumes/data/projB',
      ]);
    });
  });

  group('UT-5 blocklist per direction (AC7, E8, E9)', () {
    SelectedFolderGroups doc1(String body) => resolveFolderGroups(
      parseFolderGroups(
        'apiVersion: cube-sandbox/v1\ngroups:\n  g:\n    $body\n',
        path: filePath,
        home: home,
      ),
      ['g'],
      home: home,
    );

    test(
      'write hit -> ConfigException (every blocklisted root, both spellings)',
      () {
        for (final p in ['~/.gnupg', '~/.ssh', '~/Library/Keychains']) {
          expect(
            () => doc1('write: [$p]'),
            throwsA(isA<ConfigException>()),
            reason: 'write: [$p] must be rejected',
          );
        }
        expect(
          () => doc1('write: [/private$home/.gnupg]'),
          throwsA(isA<ConfigException>()),
          reason: '/private spelling of a home path must be rejected',
        );
      },
    );

    test('read hit -> honored + warning, never silent', () {
      final s = doc1('read: [~/.gnupg]');
      expect(s.read, ['$home/.gnupg']);
      expect(s.warnings, hasLength(1));
      expect(s.warnings.single, contains('blocklisted read path'));
      expect(s.warnings.single, contains('NEVER silent'));
    });

    test('clean selection: no warnings', () {
      expect(
        resolveFolderGroups(doc, ['projecta'], home: home).warnings,
        isEmpty,
      );
    });
  });

  group(
    'AC5 merge order (manifest -> services -> folder groups -> env knobs)',
    () {
      test(
        'position + first-occurrence-wins dedup across all four sources',
        () {
          final svc = resolveServiceGrants(const {'github'}, home: home).read;
          final r = resolveRuntime(
            const HarnessSpec(
              name: 't',
              command: ['t'],
              agentRoot: '~/.t',
              extraRead: ['/m', '/dup'],
              extraWrite: ['/mw'],
            ),
            services: const {'github'},
            cwd: '/w',
            home: home,
            env: const {
              'TMPDIR': '/private/var/folders/t/T1',
              'CUBE_SANDBOX_EXTRA_READ': '/envr:/dup',
              'CUBE_SANDBOX_EXTRA_WRITE': '/envw',
            },
            fs: _NoIO(),
            folderRead: const ['/fold', '/dup'],
            folderWrite: const ['/fw'],
          );
          expect(r.extraRead, ['/m', '/dup', ...svc, '/fold', '/envr']);
          expect(r.extraWrite, ['/mw', '/fw', '/envw']);
          expect(r.warnings, isEmpty);
        },
      );
    },
  );

  group('AC6 emit', () {
    test(
      'selected write path yields a write allow; reads re-allowed in BOTH spellings',
      () {
        final g = resolveFolderGroups(doc, ['projectb'], home: home);
        final plain = emitProfile(rt());
        final widened = emitProfile(rt(read: g.read, write: g.write));
        expect(
          widened.text,
          contains('(allow file-write* (subpath "$home/work/projectb")'),
        );
        expect(
          widened.text,
          contains(
            '(allow file-read* (subpath "$home/Library/Caches/big-model")',
          ),
        );
        expect(
          widened.text,
          contains(
            '(allow file-read* (subpath "/private$home/Library/Caches/big-model")',
          ),
        );
        // additive-only: the deny skeleton is byte-identical (PF3).
        String denies(String t) =>
            t.split('\n').where((l) => l.startsWith('(deny')).join('\n');
        expect(denies(widened.text), denies(plain.text));
      },
    );

    test('/private spelling in a group unifies with the bare form (E12)', () {
      final g = rt(read: ['/private$home/shared']);
      final t = emitProfile(g).text;
      expect(
        t.split('(allow file-read* (subpath "/private$home/shared")').length,
        2,
        reason: 'exactly one /private re-allow for the unified pair',
      );
    });
  });

  group('REG-3 key10 sensitivity (AC8, E10)', () {
    test(
      'same selection => same key10; different selection => different key10',
      () {
        final a = emitProfile(rt(read: const ['/r1'])).key10;
        final b = emitProfile(rt(read: const ['/r1'])).key10;
        final c = emitProfile(rt(read: const ['/r2'])).key10;
        final w = emitProfile(rt(write: const ['/r1'])).key10;
        expect(a, b);
        expect(a, isNot(c));
        expect(
          a,
          isNot(w),
          reason: 'direction matters: read grant != write grant',
        );
      },
    );
  });

  group('.src stamp inputs (AC8)', () {
    test(
      'folderGroupsStamp: deterministic, names groups + resolved entries',
      () {
        final s1 = folderGroupsStamp(
          resolveFolderGroups(doc, ['projectb'], home: home).groups,
        );
        final s2 = folderGroupsStamp(
          resolveFolderGroups(doc, ['projectb'], home: home).groups,
        );
        expect(s1, s2);
        expect(s1, contains('projectb'));
        expect(s1, contains('$home/work/projectb'));
        expect(s1, contains('$home/Library/Caches/big-model'));
      },
    );

    test('sourceStamp folds the selection into fp and detail', () {
      const resolved = ResolvedHarness(
        spec: HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
        source: HarnessSource.yaml,
        sourceText: 'manifest text',
      );
      final plain = sourceStamp(resolved);
      final withFolders = sourceStamp(
        resolved,
        folderStamp: 'folders.g: read=[/r] write=[]',
      );
      expect(withFolders.fp, isNot(plain.fp));
      expect(withFolders.detail, contains('folders.g'));
      expect(plain.detail, isNot(contains('folders.')));
    });
  });

  group('AC9 banner truthfulness', () {
    test(
      'group paths appear in rw/ro lines; blocklisted-read warning renders',
      () {
        final g = resolveFolderGroups(doc, ['projectb'], home: home);
        final danger = resolveFolderGroups(
          parseFolderGroups(
            'apiVersion: cube-sandbox/v1\ngroups:\n  danger:\n    read: [~/.gnupg]\n',
            path: filePath,
            home: home,
          ),
          ['danger'],
          home: home,
        );
        final lines = bannerLines(
          resolved: const ResolvedHarness(
            spec: HarnessSpec(name: 't', command: ['t'], agentRoot: '~/.t'),
            source: HarnessSource.yaml,
          ),
          runtime: rt(
            read: [...g.read, ...danger.read],
            write: g.write,
            warnings: danger.warnings,
          ),
          key10: '0123456789',
        );
        final rw = lines.firstWhere((l) => l.startsWith('   rw'));
        final ro = lines.firstWhere((l) => l.startsWith('   ro'));
        expect(rw, contains('$home/work/projectb'));
        expect(rw, contains('/Volumes/data/projB'));
        expect(ro, contains('$home/Library/Caches/big-model'));
        expect(
          lines.where((l) => l.startsWith('⚠')),
          everyElement(contains('blocklisted read path')),
          reason: 'the warning renders, never silent',
        );
      },
    );
  });
}

final class _NoIO implements RuntimeIO {
  @override
  bool isExecutable(String path) => false;
  @override
  String? shebangInterpreter(String path) => null;
  @override
  String? realpath(String path) => path;
}
