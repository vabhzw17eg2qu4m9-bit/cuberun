/// cube-sandbox CLI: `launch` · `list` · `show` · `sbpl` · `new` · `probe`.
///
/// Exit codes: 0 ok — for launch, spawn success: the confined harness is
/// running and outlives cube-sandbox (spawn-and-exit, #53) · 1 probe
/// failure · 2 config error · 64 usage · 126 fail-closed backend/spawn ·
/// under `launch --wait`: the harness's own code (signal n => 128+n).
library;

import 'dart:io' as io;

import 'exceptions.dart';
import 'launch_argv.dart';
import 'launcher.dart';
import 'preflight.dart';
import 'probe.dart';
import 'resolver.dart';
import 'runtime.dart';
import 'scaffold.dart';
import 'sbpl.dart';
import 'stage.dart';

/// cube-sandbox version (kept in one place for `--version` and CI smoke).
const String kCubeSandboxVersion = '0.2.1';

const String _usage =
    '''
cube-sandbox $kCubeSandboxVersion — kernel-confined launcher for AI harnesses

Usage:
  cube-sandbox launch [options] <profile> [args…] [-- <command…>]
      Launch a command (default: the profile's own) inside the Layer-0
      kernel profile. Spawn-and-exit: once the confined harness is
      running, cube-sandbox exits 0 (the exit code is the spawn status,
      not the harness's) — the harness keeps the terminal, its fds and
      the kernel boundary on its own. --wait blocks for the harness
      instead and forwards its exit code (signal n => 128+n). Options
      (--file/--yaml/--use-*) precede the profile; everything AFTER it
      is the harness's argv, forwarded verbatim (order preserved).
      Service grants: --use-github, --use-gitlab, --use-nvm. --yaml
      passes the manifest inline ('-' reads stdin); --yaml + --file
      together is an error. `-- <command…>` overrides the harness
      command.
  cube-sandbox list
      Enumerate profiles: presets + project .cube-sandbox/ + user ~/.cube-sandbox/.
  cube-sandbox show <profile> [--file <f> | --yaml <text|->] [--use-<service>]...
      Show resolved grants (rw / ro / denied banner).
  cube-sandbox sbpl <profile> [--file <f> | --yaml <text|->] [--use-<service>]...
      Print the exact deterministic kernel profile text.
  cube-sandbox new <name> --command <cmd> --agent-root <path>
      Scaffold .cube-sandbox/<name>.yaml (strict round-trip verified).
  cube-sandbox probe <profile> [--file <f> | --yaml <text|->] [--use-<service>]...
      Self-check confinement FROM INSIDE the profile; exit 0/1.

Env knobs:
  CUBE_SANDBOX_EXTRA_READ   colon-separated read-only grants (~ ok)
  CUBE_SANDBOX_EXTRA_WRITE  colon-separated read-write grants (~ ok;
                       ~/.ssh / ~/.gnupg / ~/Library/Keychains NEVER)

Exit codes: 0 ok (launch: spawn success — the harness outlives us) ·
1 probe failed · 2 config error · 64 usage ·
126 fail-closed (backend missing/rejecting) ·
--wait: the harness's own code (signal n => 128+n).''';

/// Parses [args], runs the verb, returns the process exit code.
Future<int> runCli(
  List<String> args, {
  void Function(String)? stdoutSink,
}) async {
  void out(String s) => (stdoutSink ?? io.stdout.writeln)(s);
  void err(String s) => io.stderr.writeln(s);

  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    err(_usage);
    return args.isEmpty ? 64 : 0;
  }
  if (args.contains('--version')) {
    out('cube-sandbox $kCubeSandboxVersion');
    return 0;
  }

  final verb = args.first;
  final rest = args.sublist(1);
  try {
    switch (verb) {
      case 'launch':
        return await _cmdLaunch(rest, err);
      case 'list':
        return _cmdList(out);
      case 'show':
        return await _cmdShow(rest, out, err);
      case 'sbpl':
        return await _cmdSbpl(rest, out, err);
      case 'new':
        return _cmdNew(rest, out, err);
      case 'probe':
        return await _cmdProbe(rest, out, err);
      default:
        err('cube-sandbox: unknown verb "$verb" (see --help)');
        return 64;
    }
  } on ConfigException catch (e) {
    err('cube-sandbox: $e');
    return 2;
  } on io.FileSystemException catch (e) {
    err('cube-sandbox: filesystem error: ${e.message} (${e.path ?? ''})');
    return 2;
  }
}

// ---------------------------------------------------------------------------
// shared option scanning: --file <f> | --use-<x> | -- (command passthrough)
// ---------------------------------------------------------------------------

final class _Opts {
  _Opts(
    this.positional,
    this.file,
    this.yaml,
    this.services,
    this.command,
    this.flags,
  );

  final List<String> positional;
  String? file;

  /// `--yaml` value: manifest TEXT, or `-` (read stdin to EOF).
  String? yaml;
  Set<String> services = <String>{};
  List<String> command; // after `--` (empty = profile default)
  Map<String, String> flags; // --flag value / --bool
}

/// Scans verb args: positional words, `--file <f>`, `--yaml <text|->`,
/// `--use-<x>…`, `--key <value>` pairs, bare boolean [boolFlags] (stored
/// in the flags map with an empty value), and everything after a bare
/// `--`.
_Opts _scanOpts(
  List<String> args,
  Set<String> valueFlags, {
  Set<String> boolFlags = const {},
}) {
  final positional = <String>[];
  final flags = <String, String>{};
  String? file;
  String? yaml;
  final services = <String>{};
  var command = <String>[];
  var i = 0;
  for (; i < args.length; i++) {
    final a = args[i];
    if (a == '--') {
      command = args.sublist(i + 1);
      break;
    }
    if (a.startsWith('--use-')) {
      services.add(a.substring(6));
      continue;
    }
    if (a == '--file') {
      if (i + 1 >= args.length) {
        throw const ConfigException('--file: requires a path argument');
      }
      file = args[++i];
      continue;
    }
    if (a == '--yaml') {
      if (i + 1 >= args.length) {
        throw const ConfigException(
          '--yaml: requires a manifest (yaml text, or - for stdin)',
        );
      }
      yaml = args[++i];
      continue;
    }
    if (a.startsWith('--') && boolFlags.contains(a.substring(2))) {
      flags[a.substring(2)] = ''; // boolean flag: presence marker
      continue;
    }
    if (a.startsWith('--') && valueFlags.contains(a.substring(2))) {
      if (i + 1 >= args.length) {
        throw ConfigException('$a: requires a value');
      }
      flags[a.substring(2)] = args[++i];
      continue;
    }
    if (a.startsWith('--')) {
      throw ConfigException('unknown option "$a"');
    }
    positional.add(a);
  }
  return _Opts(positional, file, yaml, services, command, flags);
}

Future<({ResolvedHarness resolved, HarnessRuntime runtime})> _resolveForRun(
  _Opts opts,
  String verb,
) async {
  if (opts.positional.isEmpty) {
    throw ConfigException('$verb <profile>: profile name required');
  }
  var yaml = opts.yaml;
  if (yaml == '-') {
    yaml = await readManifestStdin();
  }
  final cwd = io.Directory.current.path;
  final home = io.Platform.environment['HOME'] ?? '/';
  final resolved = HarnessResolver(
    cwd: cwd,
    home: home,
  ).resolve(opts.positional.first, file: opts.file, yaml: yaml);
  final runtime = resolveRuntime(
    resolved.spec,
    services: opts.services,
    cwd: cwd,
    home: home,
  );
  return (resolved: resolved, runtime: runtime);
}

void _printWarnings(HarnessRuntime rt, void Function(String) err) {
  for (final w in rt.warnings) {
    err('⚠  $w');
  }
}

// ---------------------------------------------------------------------------
// verbs
// ---------------------------------------------------------------------------

Future<int> _cmdLaunch(List<String> args, void Function(String) err) async {
  final split = splitLaunchArgv(args);
  // `--wait` is launch-only; strict verbs stay strict. splitLaunchArgv
  // keeps everything after the profile OUT of here — a `--wait` there is
  // the harness's argv, forwarded verbatim.
  final opts = _scanOpts(split.args, const {}, boolFlags: const {'wait'});
  final r = await _resolveForRun(opts, 'launch');
  final resolved = r.resolved;
  final runtime = r.runtime;

  final check = await preflightBackend();
  if (!check.ok) {
    err(
      'cube-sandbox: kernel backend unavailable: ${check.detail} '
      '(fail closed; nothing ran)',
    );
    return 126;
  }

  final profile = emitProfile(runtime);
  final profilePath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: profile.text,
    key10: profile.key10,
  );

  final command = opts.command.isNotEmpty
      ? opts.command
      : resolved.spec.command;
  if (command.isEmpty) {
    err('cube-sandbox: empty command after --');
    return 126;
  }

  _banner(resolved, runtime, profile.key10, profilePath, err);
  return launchConfined(
    profilePath: profilePath,
    command: [...command, ...split.tail],
    wait: opts.flags.containsKey('wait'),
    onFailClosed: err,
  );
}

int _cmdList(void Function(String) out) {
  final cwd = io.Directory.current.path;
  final home = io.Platform.environment['HOME'] ?? '/';
  for (final l in HarnessResolver(cwd: cwd, home: home).list()) {
    final desc = l.description == null ? '' : ' — ${l.description}';
    out('${l.stem.padRight(10)} ${l.source.label}$desc');
  }
  return 0;
}

Future<int> _cmdShow(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) async {
  final opts = _scanOpts(args, const {});
  final r = await _resolveForRun(opts, 'show');
  final runtime = r.runtime;
  final profile = emitProfile(runtime);
  _banner(r.resolved, runtime, profile.key10, null, out);
  return 0;
}

Future<int> _cmdSbpl(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) async {
  final opts = _scanOpts(args, const {});
  final r = await _resolveForRun(opts, 'sbpl');
  _printWarnings(r.runtime, err);
  io.stdout.write(emitProfile(r.runtime).text);
  return 0;
}

int _cmdNew(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) {
  final opts = _scanOpts(args, const {'command', 'agent-root'});
  if (opts.positional.length != 1) {
    throw const ConfigException('new <name>: exactly one name required');
  }
  final command = opts.flags['command'];
  final agentRoot = opts.flags['agent-root'];
  if (command == null || agentRoot == null) {
    throw const ConfigException(
      'new: --command <cmd> and --agent-root <path> are required',
    );
  }
  final cwd = io.Directory.current.path;
  final path = scaffoldProfile(
    name: opts.positional.first,
    command: command,
    agentRoot: agentRoot,
    projectDir: cwd,
  );
  out('scaffolded $path (strict round-trip verified)');
  return 0;
}

Future<int> _cmdProbe(
  List<String> args,
  void Function(String) out,
  void Function(String) err,
) async {
  final opts = _scanOpts(args, const {});
  final r = await _resolveForRun(opts, 'probe');
  final runtime = r.runtime;

  final check = await preflightBackend();
  if (!check.ok) {
    err(
      'cube-sandbox: kernel backend unavailable: ${check.detail} '
      '(fail closed; nothing ran)',
    );
    return 126;
  }

  final profile = emitProfile(runtime);
  final profilePath = stageProfile(
    cacheDir: projectCacheDir(runtime.projDir),
    text: profile.text,
    key10: profile.key10,
  );
  final home = io.Platform.environment['HOME'] ?? '/';
  final report = await probeHarness(
    runtime: runtime,
    profilePath: profilePath,
    home: home,
  );
  for (final c in report.checks) {
    if (c.ok) {
      out('  ok  ${c.name}');
    } else {
      out('FAIL  ${c.name}${c.info.isEmpty ? '' : ' — ${c.info}'}');
    }
  }
  out(
    '\nprobe: ${report.checks.length - report.failed} passed, '
    '${report.failed} failed',
  );
  return report.allPassed ? 0 : 1;
}

void _banner(
  ResolvedHarness resolved,
  HarnessRuntime runtime,
  String key10,
  String? profilePath,
  void Function(String) sink,
) {
  final src = resolved.path == null
      ? resolved.source.label
      : '${resolved.source.label} (${resolved.path})';
  sink(
    '⛨ ${resolved.spec.name} under cube-sandbox '
    '(profile $key10${profilePath == null ? '' : ': $profilePath'})',
  );
  sink('   source : $src');
  sink(
    '   rw     : ${runtime.projDir} · ${runtime.agentRoot} · ${runtime.tmp}'
    '${runtime.extraWrite.isEmpty ? '' : ' · ${runtime.extraWrite.join(' · ')}'}',
  );
  sink(
    '   ro     : system dirs'
    '${runtime.runtimeDirs.isEmpty ? '' : ' · runtime (${runtime.runtimeDirs.join(' · ')})'}'
    '${runtime.extraRead.isEmpty ? '' : ' · ${runtime.extraRead.join(' · ')}'}',
  );
  sink(
    '   denied : /Users /private/var /Volumes /Network /home /net '
    '(except grants above — blanket read-deny unbuildable, E1) · '
    'all writes outside rw · network OPEN (cubes deny net inside)',
  );
  if (runtime.services.isNotEmpty) {
    final used = runtime.services.toList()..sort();
    final joined = used.join(', ');
    sink('   use    : $joined');
  }
  for (final w in runtime.warnings) {
    sink('⚠  $w');
  }
}
