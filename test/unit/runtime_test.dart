import 'package:cuberun/src/harness_manifest.dart';
import 'package:cuberun/src/runtime.dart';
import 'package:test/test.dart';

/// E5 — PATH lookup happens INSIDE the sandbox: the dir holding the
/// command (and its shebang interpreter) must be read-granted; the
/// runtime-prefix detection covers `<prefix>/lib` module trees.
/// Also: agent-root env override, dot-dir widening, $TMPDIR realpath.
void main() {
  const home = '/Users/dev';

  test('runtimePrefix: <prefix>/bin -> <prefix>, others unchanged', () {
    expect(runtimePrefix('/opt/homebrew/bin'), '/opt/homebrew');
    expect(
      runtimePrefix('/Users/dev/.nvm/versions/node/v22.0.0/bin'),
      '/Users/dev/.nvm/versions/node/v22.0.0',
    );
    expect(runtimePrefix('/usr/local/libexec'), '/usr/local/libexec');
  });

  test('widenToDotParent: ~/.pi/agent -> ~/.pi; non-dot parent unchanged', () {
    expect(widenToDotParent('$home/.pi/agent'), '$home/.pi');
    expect(
      widenToDotParent('$home/.omp/agent/state'),
      '$home/.omp/agent/state',
    ); // parent 'agent' is not a dot-dir
    expect(widenToDotParent('/opt/tools/agent'), '/opt/tools/agent');
    expect(widenToDotParent('/agent'), '/agent');
  });

  group('runtime dir detection (E5)', () {
    test('absolute command path -> dirname prefix', () {
      final io = _FakeIO(executables: {'/opt/mytool/bin/hx'}, shebangs: {});
      final rt = resolveRuntime(
        _spec(command: ['/opt/mytool/bin/hx']),
        services: const {},
        cwd: '/w',
        home: home,
        env: const {},
        fs: io,
      );
      expect(rt.runtimeDirs, ['/opt/mytool']);
    });

    test('PATH lookup finds the command dir', () {
      final io = _FakeIO(
        executables: {'/Users/dev/.nvm/versions/node/v22.0.0/bin/node'},
      );
      final rt = resolveRuntime(
        _spec(command: ['node']),
        services: const {},
        cwd: '/w',
        home: home,
        env: {'PATH': '/usr/bin:/Users/dev/.nvm/versions/node/v22.0.0/bin'},
        fs: io,
      );
      expect(rt.runtimeDirs, ['/Users/dev/.nvm/versions/node/v22.0.0']);
    });

    test('shebang interpreter dir granted too (node for pi)', () {
      final nodeBin = '/Users/dev/.nvm/versions/node/v22.0.0/bin';
      final io = _FakeIO(
        executables: {'/usr/local/bin/pi', '$nodeBin/node'},
        shebangs: {'/usr/local/bin/pi': '$nodeBin/node'},
      );
      final rt = resolveRuntime(
        _spec(command: ['pi']),
        services: const {},
        cwd: '/w',
        home: home,
        env: {'PATH': '/usr/local/bin'},
        fs: io,
      );
      expect(rt.runtimeDirs, contains('/usr/local'));
      expect(rt.runtimeDirs, contains('/Users/dev/.nvm/versions/node/v22.0.0'));
    });

    test('relative command resolved against cwd', () {
      final io = _FakeIO(executables: {'/w/tools/run.sh'});
      final rt = resolveRuntime(
        _spec(command: ['tools/run.sh']),
        services: const {},
        cwd: '/w',
        home: home,
        env: const {},
        fs: io,
      );
      expect(rt.runtimeDirs, ['/w/tools']);
    });

    test(
      'missing command yields no runtime dirs (preflight catches later)',
      () {
        final rt = resolveRuntime(
          _spec(command: ['nonexistent-harness']),
          services: const {},
          cwd: '/w',
          home: home,
          env: const {},
          fs: _FakeIO(),
        );
        expect(rt.runtimeDirs, isEmpty);
      },
    );
  });

  group('agent root resolution', () {
    test('manifest root expanded from ~', () {
      final rt = _resolveAgentRoot(agentRoot: '~/.myh');
      expect(rt.agentRoot, '$home/.myh');
    });

    test('agentRootEnv overrides manifest root', () {
      final rt = _resolveAgentRoot(
        agentRoot: '~/.default',
        agentRootEnv: 'MYH_DIR',
        env: {'MYH_DIR': '/opt/state'},
      );
      expect(rt.agentRoot, '/opt/state');
    });

    test('empty env value falls back to manifest root', () {
      final rt = _resolveAgentRoot(
        agentRoot: '~/.default',
        agentRootEnv: 'MYH_DIR',
        env: {'MYH_DIR': '  '},
      );
      expect(rt.agentRoot, '$home/.default');
    });

    test('pi-style: env dir under dot-parent widened once', () {
      final rt = _resolveAgentRoot(
        agentRoot: '~/.pi/agent',
        agentRootEnv: 'PI_CODING_AGENT_DIR',
        widen: true,
        env: {'PI_CODING_AGENT_DIR': '$home/.pi/agent'},
      );
      expect(rt.agentRoot, '$home/.pi');
    });

    test('pi preset default widens ~/.pi/agent -> ~/.pi', () {
      final rt = _resolveAgentRoot(agentRoot: '~/.pi/agent', widen: true);
      expect(rt.agentRoot, '$home/.pi');
    });

    test('omp preset default (no widen): ~/.omp stays', () {
      final rt = _resolveAgentRoot(agentRoot: '~/.omp');
      expect(rt.agentRoot, '$home/.omp');
    });
  });

  test(r'$TMPDIR realpath:ed (E2) — /var spelling resolved to /private', () {
    final rt = _resolveAgentRoot(env: {'TMPDIR': '/var/folders/ab/T9'});
    expect(rt.tmp, '/private/var/folders/ab/T9');
  });
}

HarnessRuntime _resolveAgentRoot({
  String agentRoot = '~/.myh',
  String? agentRootEnv,
  bool widen = false,
  Map<String, String> env = const {},
}) => resolveRuntime(
  _spec(agentRoot: agentRoot, agentRootEnv: agentRootEnv, widen: widen),
  services: const {},
  cwd: '/w',
  home: '/Users/dev',
  env: env,
  fs: _FakeIO(),
);

HarnessSpec _spec({
  List<String> command = const ['h'],
  String agentRoot = '~/.myh',
  String? agentRootEnv,
  bool widen = false,
}) => HarnessSpec(
  name: 't',
  command: command,
  agentRoot: agentRoot,
  agentRootEnv: agentRootEnv,
  widenToDotParent: widen,
);

final class _FakeIO implements RuntimeIO {
  _FakeIO({this.executables = const {}, this.shebangs = const {}});

  final Set<String> executables;
  final Map<String, String> shebangs;

  @override
  bool isExecutable(String path) => executables.contains(path);

  @override
  String? shebangInterpreter(String path) => shebangs[path];

  @override
  String? realpath(String path) {
    if (path.startsWith('/var/')) return '/private$path';
    return path;
  }
}
