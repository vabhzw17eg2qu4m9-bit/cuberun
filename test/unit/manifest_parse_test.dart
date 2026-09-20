import 'package:cuberun/src/exceptions.dart';
import 'package:cuberun/src/harness_manifest.dart';
import 'package:test/test.dart';

/// AC1 — strict parse: every schema violation throws ConfigException
/// naming the YAML path; valid documents parse fully.
void main() {
  const good = '''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: pi
  description: test harness
spec:
  command: pi
  agentRoot: ~/.pi
''';

  group('AC1 strict parse table', () {
    test('valid document parses fully', () {
      final spec = HarnessSpec.fromYamlText(good);
      expect(spec.name, 'pi');
      expect(spec.description, 'test harness');
      expect(spec.command, ['pi']);
      expect(spec.agentRoot, '~/.pi');
      expect(spec.network, HarnessNetwork.open);
    });

    void rejects(String label, String yaml, dynamic pathPattern) {
      test(label, () {
        expect(
          () => HarnessSpec.fromYamlText(yaml),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              pathPattern,
            ),
          ),
        );
      });
    }

    rejects(
      'wrong apiVersion',
      good.replaceFirst('cuberun/v1', 'cuberun/v2'),
      contains('apiVersion'),
    );
    rejects('missing apiVersion', '''
kind: Harness
metadata:
  name: pi
spec:
  command: pi
  agentRoot: ~/.pi
''', contains('apiVersion'));
    rejects(
      'wrong kind',
      good.replaceFirst('kind: Harness', 'kind: Profile'),
      contains('kind'),
    );
    rejects('unknown root key', '$good\nextra: 1', contains('.extra'));
    rejects(
      'bad name (uppercase)',
      good.replaceFirst('name: pi', 'name: Pi'),
      contains('metadata.name'),
    );
    rejects(
      'bad name (leading dash)',
      good.replaceFirst('name: pi', 'name: -pi'),
      contains('metadata.name'),
    );
    rejects(
      'unknown metadata key',
      good.replaceFirst('  name: pi', '  name: pi\n  labels: x'),
      contains('metadata.labels'),
    );
    rejects('missing spec', '''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: pi
''', contains('spec'));
    rejects(
      'unknown spec key',
      good.replaceFirst('  agentRoot: ~/.pi', '  agentRoot: ~/.pi\n  quota: 3'),
      contains('spec.quota'),
    );
    rejects('missing command', '''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: pi
spec:
  agentRoot: ~/.pi
''', contains('spec.command'));
    rejects(
      'empty command',
      good.replaceFirst('command: pi', "command: ''"),
      contains('spec.command'),
    );
    rejects(
      'command list with empty entry',
      good.replaceFirst('command: pi', "command: ['pi', '']"),
      contains('spec.command[1]'),
    );
    rejects(
      'relative agentRoot',
      good.replaceFirst('agentRoot: ~/.pi', 'agentRoot: relative/path'),
      contains('spec.agentRoot'),
    );
    rejects(
      'agentRoot .. climb',
      good.replaceFirst('agentRoot: ~/.pi', 'agentRoot: /tmp/../etc'),
      contains('spec.agentRoot'),
    );
    rejects(
      'agentRoot with quote (SBPL literal injection, E4)',
      good.replaceFirst('agentRoot: ~/.pi', 'agentRoot: /tmp/x"y'),
      contains('spec.agentRoot'),
    );
    rejects(
      'agentRoot with newline (E4)',
      'apiVersion: cuberun/v1\nkind: Harness\nmetadata:\n  name: pi\nspec:\n  command: pi\n  agentRoot: "/tmp/a\\nb"\n',
      contains('spec.agentRoot'),
    );
    rejects(
      'trailing slash agentRoot',
      good.replaceFirst('agentRoot: ~/.pi', 'agentRoot: /tmp/xx/'),
      contains('spec.agentRoot'),
    );
    rejects(
      'non-list extraRead',
      good.replaceFirst(
        '  agentRoot: ~/.pi',
        '  agentRoot: ~/.pi\n  extraRead: /tmp',
      ),
      contains('spec.extraRead'),
    );
    rejects(
      'extraRead entry with ..',
      good.replaceFirst(
        '  agentRoot: ~/.pi',
        '  agentRoot: ~/.pi\n  extraRead: [/ok, /bad/../x]',
      ),
      contains('spec.extraRead[1]'),
    );
    rejects(
      'network closed (v1 has open only)',
      good.replaceFirst(
        '  agentRoot: ~/.pi',
        '  agentRoot: ~/.pi\n  network: filtered',
      ),
      contains('spec.network'),
    );
    rejects(
      'bad agentRootEnv',
      good.replaceFirst(
        '  agentRoot: ~/.pi',
        '  agentRoot: ~/.pi\n  agentRootEnv: 1BAD',
      ),
      contains('spec.agentRootEnv'),
    );
    rejects(
      'widenToDotParent non-bool',
      good.replaceFirst(
        '  agentRoot: ~/.pi',
        '  agentRoot: ~/.pi\n  widenToDotParent: yes-please',
      ),
      contains('spec.widenToDotParent'),
    );
    rejects('not a map', '- a\n- b', contains('must be a yaml map'));
  });

  test('command as argv list parses to argv', () {
    final spec = HarnessSpec.fromYamlText('''
apiVersion: cuberun/v1
kind: Harness
metadata:
  name: pi
spec:
  command: ['/usr/local/bin/pi', '--verbose']
  agentRoot: ~/.pi
''');
    expect(spec.command, ['/usr/local/bin/pi', '--verbose']);
  });

  test('toYamlText round-trips through the strict parser', () {
    final spec = HarnessSpec(
      name: 'round-trip',
      command: ['myharness', '-d'],
      agentRoot: '~/.myharness',
      agentRootEnv: 'MYH_DIR',
      widenToDotParent: true,
      extraRead: const ['~/.config/myh'],
      extraWrite: const ['/tmp/myh-cache'],
    );
    final reparsed = HarnessSpec.fromYamlText(spec.toYamlText());
    expect(reparsed.name, spec.name);
    expect(reparsed.command, spec.command);
    expect(reparsed.agentRoot, spec.agentRoot);
    expect(reparsed.agentRootEnv, spec.agentRootEnv);
    expect(reparsed.widenToDotParent, spec.widenToDotParent);
    expect(reparsed.extraRead, spec.extraRead);
    expect(reparsed.extraWrite, spec.extraWrite);
  });
}
