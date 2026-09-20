import 'package:cuberun/src/exceptions.dart';
import 'package:cuberun/src/paths.dart';
import 'package:cuberun/src/service_grants.dart';
import 'package:test/test.dart';

/// E4 — path sanitation (SBPL literal injection impossible-by-construction)
/// and env-knob parsing.
void main() {
  group('E4 sanitizeManifestPath', () {
    void rejects(Object? value, String why) {
      test('rejects $why', () {
        expect(
          () => sanitizeManifestPath(value, 'test.where'),
          throwsA(isA<ConfigException>()),
        );
      });
    }

    rejects(42, 'non-string');
    rejects('', 'empty');
    rejects('   ', 'whitespace-only');
    rejects('relative/path', 'relative path');
    rejects('~/../etc', 'tilde + climb');
    rejects('/tmp/../etc', 'dotdot climb');
    rejects('/tmp/a"b', 'embedded quote');
    rejects('/tmp/a\nb', 'embedded newline');
    rejects('/tmp/a\rb', 'embedded carriage return');
    rejects('/tmp/a\x00b', 'embedded NUL');
    rejects('/trailing/', 'trailing slash');
    rejects('~otheruser/x', 'foreign-home tilde');

    test('accepts absolute, ~ and ~/-prefixed', () {
      expect(sanitizeManifestPath('/opt/x', 'w'), '/opt/x');
      expect(sanitizeManifestPath('~', 'w'), '~');
      expect(sanitizeManifestPath('~/.config', 'w'), '~/.config');
    });
  });

  group('expandTilde', () {
    test('expands ~ and ~/ against home', () {
      expect(expandTilde('~', '/Users/a'), '/Users/a');
      expect(expandTilde('~/.pi', '/Users/a'), '/Users/a/.pi');
      expect(expandTilde('/abs', '/Users/a'), '/abs');
    });
  });

  group('parseEnvPathList (env knobs)', () {
    test('null/empty yields empty', () {
      expect(parseEnvPathList(null, '/h'), isEmpty);
      expect(parseEnvPathList('', '/h'), isEmpty);
      expect(parseEnvPathList('  ', '/h'), isEmpty);
    });

    test('colon-separated, trimmed, tilde-expanded, empties dropped', () {
      expect(parseEnvPathList(' /tmp/x :~/.config::/var/y ', '/Users/a'), [
        '/tmp/x',
        '/Users/a/.config',
        '/var/y',
      ]);
    });
  });

  group('bothSpellingsOf (E2)', () {
    test('/var gets /private/var and back', () {
      expect(bothSpellingsOf('/var'), containsAll(['/var', '/private/var']));
      expect(
        bothSpellingsOf('/private/var'),
        containsAll(['/var', '/private/var']),
      );
    });

    test('/Users gets /private/Users and back', () {
      expect(
        bothSpellingsOf('/Users'),
        containsAll(['/Users', '/private/Users']),
      );
      expect(
        bothSpellingsOf('/Users/a/.ssh'),
        containsAll(['/Users/a/.ssh', '/private/Users/a/.ssh']),
      );
    });

    test('/etc and /tmp both spellings', () {
      expect(bothSpellingsOf('/etc/ssl'), contains('/private/etc/ssl'));
      expect(bothSpellingsOf('/tmp'), contains('/private/tmp'));
    });

    test('unrelated paths unchanged', () {
      expect(bothSpellingsOf('/opt/homebrew'), ['/opt/homebrew']);
    });
  });
}
