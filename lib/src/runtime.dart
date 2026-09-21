/// HarnessRuntime: the resolved machine facts a profile is built from —
/// cwd, agent root (env override + dot-dir widening), realpath($TMPDIR),
/// env-knob grants, service grants, and the runtime prefixes of the
/// launch command itself (PATH lookup happens INSIDE the sandbox — E5).
library;

import 'dart:io' as io;

import 'exceptions.dart';
import 'harness_manifest.dart';
import 'paths.dart';
import 'service_grants.dart';

/// Filesystem probes the runtime resolver needs (injectable for UT).
abstract class RuntimeIO {
  /// Whether [path] exists and is executable (PATH lookup candidate).
  bool isExecutable(String path);

  /// The interpreter of a `#!` shebang first line, or null.
  String? shebangInterpreter(String path);

  /// Real path (symlinks resolved) or null when resolution fails.
  String? realpath(String path);
}

/// dart:io-backed default probes.
final class FsRuntimeIO implements RuntimeIO {
  /// Stateless - usable as const FsRuntimeIO().
  const FsRuntimeIO();

  @override
  bool isExecutable(String path) {
    final f = io.File(path);
    if (!f.existsSync()) return false;
    return (f.statSync().mode & 0x49) != 0; // any x bit (0o111 = 0x49)
  }

  @override
  String? shebangInterpreter(String path) {
    final f = io.File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    if (bytes.length < 3 || bytes[0] != 0x23 || bytes[1] != 0x21) return null;
    var nl = bytes.indexOf(0x0a, 2);
    if (nl < 0) nl = bytes.length;
    final line = String.fromCharCodes(bytes.sublist(2, nl)).trim();
    if (line.isEmpty) return null;
    return line.split(RegExp(r'\s+')).first;
  }

  @override
  String? realpath(String path) {
    try {
      final resolved = io.File(path).resolveSymbolicLinksSync();
      // For directories File works too, but keep Directory for accuracy.
      return resolved;
    } catch (_) {
      try {
        return io.Directory(path).resolveSymbolicLinksSync();
      } catch (_) {
        return null;
      }
    }
  }
}

/// Fully-resolved facts the SBPL emitter consumes. Everything here is
/// absolute, expanded, and deterministic given (manifest, machine facts).
final class HarnessRuntime {
  /// Creates a resolved runtime.
  const HarnessRuntime({
    required this.projDir,
    required this.agentRoot,
    required this.tmp,
    this.extraRead = const [],
    this.extraWrite = const [],
    this.runtimeDirs = const [],
    this.services = const {},
    this.warnings = const [],
  });

  /// Project directory (cwd at launch) — read-write.
  final String projDir;

  /// Effective agent state root (env override + widening applied).
  final String agentRoot;

  /// realpath($TMPDIR) — the /private spelling the kernel sees (E2).
  final String tmp;

  /// Read-only grants: manifest extraRead + service read + env knob.
  final List<String> extraRead;

  /// Read-write grants: manifest extraWrite + service write + env knob.
  final List<String> extraWrite;

  /// Runtime prefixes of the launch command + its shebang interpreter
  /// (E5 — the dir holding the command must be readable or nothing
  /// starts; the parent covers `<prefix>/lib` module trees).
  final List<String> runtimeDirs;

  /// The `--use-*` flag set folded into this runtime (banners/keying).
  final Set<String> services;

  /// Non-fatal operator acknowledgements (e.g. blocklisted EXTRA_READ).
  final List<String> warnings;

  /// Returns a copy with [extraRead]/[extraWrite] extended (deduped) —
  /// used by probe variants.
  HarnessRuntime withGrants({List<String>? read, List<String>? write}) {
    List<String> merge(List<String> base, List<String> add) {
      final merged = <String>[...base];
      for (final p in add) {
        if (!merged.contains(p)) merged.add(p);
      }
      return merged;
    }

    return HarnessRuntime(
      projDir: projDir,
      agentRoot: agentRoot,
      tmp: tmp,
      extraRead: read == null ? extraRead : merge(extraRead, read),
      extraWrite: write == null ? extraWrite : merge(extraWrite, write),
      runtimeDirs: runtimeDirs,
      services: services,
      warnings: warnings,
    );
  }
}

/// Parent prefix of a bin dir: `<prefix>/bin` -> `<prefix>` (module trees
/// under `<prefix>/lib` stay readable); other dirs unchanged.
String runtimePrefix(String binDir) {
  final parts = binDir.split('/');
  if (parts.isNotEmpty && parts.last == 'bin') {
    return parts.length <= 2
        ? '/'
        : parts.sublist(0, parts.length - 1).join('/');
  }
  return binDir;
}

/// Resolves a [HarnessSpec] + `--use-*` services + machine facts into a
/// [HarnessRuntime].
///
/// Throws [ConfigException] when a DECLARATIVE source (manifest paths,
/// service catalog, EXTRA_WRITE env knob) touches an ungrantable root
/// (E10). `CUBE_SANDBOX_EXTRA_READ` is the single operator escape hatch:
/// honored, never silent — it lands in `warnings`.
HarnessRuntime resolveRuntime(
  HarnessSpec spec, {
  required Set<String> services,
  String? cwd,
  String? home,
  Map<String?, String?>? env,
  RuntimeIO fs = const FsRuntimeIO(),
}) {
  final cwdResolved = cwd ?? io.Directory.current.path;
  final homeResolved = home ?? io.Platform.environment['HOME'] ?? '/';
  final envResolved = env ?? io.Platform.environment;
  return _resolve(
    spec,
    services: services,
    cwd: cwdResolved,
    home: homeResolved,
    env: envResolved,
    io: fs,
  );
}

// ---------------------------------------------------------------------------
// internals (kept in one place, testable via the public signature)
// ---------------------------------------------------------------------------

HarnessRuntime _resolve(
  HarnessSpec spec, {
  required Set<String> services,
  required String cwd,
  required String home,
  required Map<String?, String?> env,
  required RuntimeIO io,
}) {
  final agentRoot = _resolveAgentRootPath(spec, home: home, env: env);

  // --- declarative grants (manifest) + ungrantable check (E10).
  final manifestRead = [for (final p in spec.extraRead) expandTilde(p, home)];
  final manifestWrite = [for (final p in spec.extraWrite) expandTilde(p, home)];
  final violations = ungrantableViolations([
    agentRoot,
    ...manifestRead,
    ...manifestWrite,
  ], home);
  if (violations.isNotEmpty) {
    throw ConfigException(
      'ungrantable path(s) from manifest "${spec.name}": '
      '${violations.join(', ')} — ~/.ssh, ~/.gnupg and ~/Library/Keychains '
      'are never grantable (E10)',
    );
  }

  // --- service grants (fail-closed on unknown; catalog order for text
  //     determinism regardless of flag order — E9).
  final grants = resolveServiceGrants(services, home: home);
  final grantViolations = ungrantableViolations([
    ...grants.read,
    ...grants.write,
  ], home);
  if (grantViolations.isNotEmpty) {
    // Impossible with the shipped catalog — a bug, not a config issue.
    throw ConfigException(
      'service catalog regression: ungrantable path(s) '
      '${grantViolations.join(', ')} (E10)',
    );
  }

  // --- env knobs: CUBE_SANDBOX_EXTRA_WRITE never blocklisted; EXTRA_READ is
  //     the operator escape hatch — honored but never silent.
  final knobs = _resolveEnvKnobs(env, home: home);

  return HarnessRuntime(
    projDir: cwd,
    agentRoot: agentRoot,
    tmp: _resolveTmp(env, io),
    extraRead: _mergeDistinct([manifestRead, grants.read, knobs.read]),
    extraWrite: _mergeDistinct([manifestWrite, grants.write, knobs.write]),
    runtimeDirs: _runtimeDirsFor(spec.command, cwd: cwd, env: env, io: io),
    services: Set.of(services),
    warnings: List.unmodifiable(knobs.warnings),
  );
}

/// Env-knob grants (`CUBE_SANDBOX_EXTRA_WRITE` / `CUBE_SANDBOX_EXTRA_READ`) plus the
/// resulting operator warnings.
({List<String> read, List<String> write, List<String> warnings})
_resolveEnvKnobs(Map<String?, String?> env, {required String home}) {
  final warnings = <String>[];
  final envWrite = parseEnvPathList(env['CUBE_SANDBOX_EXTRA_WRITE'], home);
  final writeViolations = ungrantableViolations(envWrite, home);
  if (writeViolations.isNotEmpty) {
    throw ConfigException(
      'CUBE_SANDBOX_EXTRA_WRITE carries ungrantable path(s) '
      '${writeViolations.join(', ')} — writes to ~/.ssh, ~/.gnupg or '
      '~/Library/Keychains are never grantable (E10)',
    );
  }
  final envRead = parseEnvPathList(env['CUBE_SANDBOX_EXTRA_READ'], home);
  for (final v in ungrantableViolations(envRead, home)) {
    warnings.add(
      'CUBE_SANDBOX_EXTRA_READ carries blocklisted path $v — operator override '
      'honored, NEVER silent (E10)',
    );
  }
  return (read: envRead, write: envWrite, warnings: warnings);
}

/// Agent root: manifest value (or `agentRootEnv` override), then one
/// dot-dir widening when `widenToDotParent` is set.
String _resolveAgentRootPath(
  HarnessSpec spec, {
  required String home,
  required Map<String?, String?> env,
}) {
  var agentRoot = expandTilde(spec.agentRoot, home);
  final envName = spec.agentRootEnv;
  if (envName != null) {
    final v = env[envName];
    if (v != null && v.trim().isNotEmpty) {
      agentRoot = sanitizeManifestPath(
        expandTilde(v.trim(), home),
        'env($envName)',
      );
    }
  }
  if (spec.widenToDotParent) agentRoot = widenToDotParent(agentRoot);
  return agentRoot;
}

/// `$TMPDIR`: realpath to the /private spelling the kernel sees (E2);
/// unset/empty falls back to `/tmp`.
String _resolveTmp(Map<String?, String?> env, RuntimeIO io) {
  final tmpRaw = env['TMPDIR'] != null && env['TMPDIR']!.trim().isNotEmpty
      ? env['TMPDIR']!
      : '/tmp';
  return io.realpath(tmpRaw) ?? tmpRaw;
}

/// Ordered dedup across grant lists — first occurrence wins (manifest,
/// then service grants, then env knobs).
List<String> _mergeDistinct(List<List<String>> lists) {
  final out = <String>[];
  for (final l in lists) {
    for (final p in l) {
      if (!out.contains(p)) out.add(p);
    }
  }
  return out;
}

/// `~/.pi/agent` -> `~/.pi`: widen when the PARENT is a dot-dir
/// (skills/themes/keybindings live next to agent state). Applied once.
String widenToDotParent(String path) {
  final parts = path.split('/');
  if (parts.length < 2) return path;
  final parent = parts.sublist(0, parts.length - 1).join('/');
  final parentName = parts[parts.length - 2];
  if (parentName.startsWith('.') && parentName.length > 1) return parent;
  return path;
}

List<String> _runtimeDirsFor(
  List<String> command, {
  required String cwd,
  required Map<String?, String?> env,
  required RuntimeIO io,
}) {
  final dirs = <String>[];
  void addPrefix(String dir) {
    final prefix = runtimePrefix(dir);
    if (!dirs.contains(prefix)) dirs.add(prefix);
  }

  String? findCommandDir(String argv0) {
    if (argv0.contains('/')) {
      final abs = argv0.startsWith('/') ? argv0 : '$cwd/$argv0';
      return io.isExecutable(abs) ? _dirname(abs) : null;
    }
    final path = env['PATH'] ?? '';
    for (final dir in path.split(':')) {
      if (dir.trim().isEmpty) continue;
      final candidate = dir.startsWith('/')
          ? '$dir/$argv0'
          : '$cwd/$dir/$argv0';
      if (io.isExecutable(candidate)) return _dirname(candidate);
    }
    return null;
  }

  final argv0 = command.first;
  final dir = findCommandDir(argv0);
  if (dir != null) {
    addPrefix(dir);
    final exe = argv0.contains('/')
        ? (argv0.startsWith('/') ? argv0 : '$cwd/$argv0')
        : '$dir/$argv0';
    // shebang interpreter (e.g. node for pi) + one more level (rare).
    var interp = io.shebangInterpreter(exe);
    var level = 0;
    while (interp != null && level < 2) {
      final interpDir = findCommandDir(interp);
      if (interpDir == null) break;
      addPrefix(interpDir);
      interp = io.shebangInterpreter(
        interp.contains('/') ? interp : '$interpDir/$interp',
      );
      level++;
    }
  }
  return dirs;
}

String _dirname(String p) {
  final i = p.lastIndexOf('/');
  if (i <= 0) return '/';
  return p.substring(0, i);
}
