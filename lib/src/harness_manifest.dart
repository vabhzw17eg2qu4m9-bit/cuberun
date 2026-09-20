/// The harness manifest (`HarnessSpec`): a strict yaml document naming one
/// AI harness launch and the folder grants of its Layer-0 kernel profile.
///
/// ```yaml
/// apiVersion: cuberun/v1     # required, exactly 'cuberun/v1'
/// kind: Harness              # required, exactly 'Harness'
/// metadata:
///   name: pi                 # required, ^[a-z][a-z0-9-]*$
///   description: "…"         # optional
/// spec:
///   command: pi              # required: string or argv list
///   agentRoot: ~/.pi         # required: absolute or ~/ (no "..", quotes…)
///   agentRootEnv: PI_…       # optional: env var overriding agentRoot
///   widenToDotParent: true   # optional: ~/.pi/agent -> ~/.pi
///   extraRead:  [...]        # optional: read-only grants
///   extraWrite: [...]        # optional: read-write grants
///   network: open            # optional: 'open' only in v1
/// ```
///
/// Parsing is STRICT: any schema problem (wrong apiVersion/kind, bad name,
/// unknown key at ANY level, missing/empty command, relative or unsafe
/// agentRoot, non-list extraRead…) throws [ConfigException] naming the
/// YAML path (AC1). The same parser consumes presets and user files —
/// no drift (AC2).
library;

import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'paths.dart';

final RegExp _namePattern = RegExp(r'^[a-z][a-z0-9-]*$');
final RegExp _envNamePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// Network stance of a Layer-0 profile. v1 ships `open` only: SBPL
/// remote filters accept IP literals, not hostnames, while LLM endpoints
/// sit on rotating CDN IPs (E1). Per-task denies are the inner cubes' job.
enum HarnessNetwork {
  /// `(allow network*)` — the deliberate Layer-0 default.
  open;

  /// Parses the `spec.network:` label, throwing [ConfigException] on
  /// anything but `open` in v1.
  static HarnessNetwork parse(Object? node, String where) => switch (node) {
    null => open,
    'open' => open,
    _ => throw ConfigException(
      '$where: must be "open" in v1, got ${renderValue(node)}',
    ),
  };
}

/// A parsed harness manifest (identity + launch command + folder grants).
final class HarnessSpec {
  /// Creates a spec; defaults mirror the yaml schema.
  const HarnessSpec({
    required this.name,
    required this.command,
    required this.agentRoot,
    this.description,
    this.agentRootEnv,
    this.widenToDotParent = false,
    this.extraRead = const [],
    this.extraWrite = const [],
    this.network = HarnessNetwork.open,
  });

  /// Harness name, `^[a-z][a-z0-9-]*$` (enforced at parse).
  final String name;

  /// Optional human-readable description (shown by `cuberun list`).
  final String? description;

  /// Launch argv; `spec.command` as a string becomes `[command]`.
  final List<String> command;

  /// Default state root, `~`-lexical as written (expanded at resolve).
  final String agentRoot;

  /// Env var that, when set non-empty, overrides [agentRoot] at resolve.
  final String? agentRootEnv;

  /// Widen a dot-dir root: `~/.pi/agent` -> `~/.pi` (skills/themes live
  /// next to agent state).
  final bool widenToDotParent;

  /// Extra read-only grants (lexical, `~` allowed).
  final List<String> extraRead;

  /// Extra read-write grants (lexical, `~` allowed).
  final List<String> extraWrite;

  /// Network stance (open only in v1).
  final HarnessNetwork network;

  /// Parses manifest yaml TEXT (used by presets, resolver and scaffold
  /// round-trips). [sourcePath] names the document in error messages.
  static HarnessSpec fromYamlText(String text, {String sourcePath = 'manifest'}) {
    final Object? node = loadYaml(text);
    return HarnessSpec.fromYaml(node, sourcePath: sourcePath);
  }

  /// Parses an already-loaded yaml node.
  factory HarnessSpec.fromYaml(Object? node, {String sourcePath = 'manifest'}) {
    if (node is! YamlMap) {
      throw ConfigException(
        '$sourcePath: must be a yaml map, got ${node.runtimeType}',
      );
    }
    _checkKeys(node, const {'apiVersion', 'kind', 'metadata', 'spec'}, sourcePath);

    final api = node['apiVersion'];
    if (api == null) {
      throw ConfigException('$sourcePath.apiVersion: required (expected "cuberun/v1")');
    }
    if (api is! String || api != 'cuberun/v1') {
      throw ConfigException(
        '$sourcePath.apiVersion: must be "cuberun/v1", got ${renderValue(api)}',
      );
    }

    final kind = node['kind'];
    if (kind == null) {
      throw ConfigException('$sourcePath.kind: required (expected "Harness")');
    }
    if (kind is! String || kind != 'Harness') {
      throw ConfigException(
        '$sourcePath.kind: must be "Harness", got ${renderValue(kind)}',
      );
    }

    final metadata = node['metadata'];
    if (metadata is! YamlMap) {
      throw ConfigException(
        '$sourcePath.metadata: must be a yaml map, got ${metadata.runtimeType}',
      );
    }
    _checkKeys(metadata, const {'name', 'description'}, '$sourcePath.metadata');
    final name = metadata['name'];
    if (name is! String || !_namePattern.hasMatch(name)) {
      throw ConfigException(
        '$sourcePath.metadata.name: must match ^[a-z][a-z0-9-]*\$, '
        'got ${renderValue(name)}',
      );
    }
    final description = metadata['description'];
    if (description != null && description is! String) {
      throw ConfigException(
        '$sourcePath.metadata.description: must be a string, '
        'got ${description.runtimeType}',
      );
    }

    final spec = node['spec'];
    if (spec is! YamlMap) {
      throw ConfigException(
        '$sourcePath.spec: must be a yaml map, got ${spec.runtimeType}',
      );
    }
    _checkKeys(
      spec,
      const {
        'command',
        'agentRoot',
        'agentRootEnv',
        'widenToDotParent',
        'extraRead',
        'extraWrite',
        'network',
      },
      '$sourcePath.spec',
    );

    // command: string or argv list, required non-empty (AC1).
    final List<String> command;
    final cmdNode = spec['command'];
    if (cmdNode == null) {
      throw ConfigException('$sourcePath.spec.command: required');
    } else if (cmdNode is String) {
      if (cmdNode.trim().isEmpty) {
        throw ConfigException('$sourcePath.spec.command: must be non-empty');
      }
      command = [cmdNode];
    } else if (cmdNode is YamlList) {
      command = [
        for (var i = 0; i < cmdNode.length; i++)
          _sanitizeArgvEntry(cmdNode[i], '$sourcePath.spec.command[$i]'),
      ];
      if (command.isEmpty) {
        throw ConfigException('$sourcePath.spec.command: must be non-empty');
      }
    } else {
      throw ConfigException(
        '$sourcePath.spec.command: must be a string or argv list, '
        'got ${cmdNode.runtimeType}',
      );
    }

    final agentRoot = sanitizeManifestPath(
      spec['agentRoot'],
      '$sourcePath.spec.agentRoot',
    );

    final agentRootEnvNode = spec['agentRootEnv'];
    if (agentRootEnvNode != null &&
        (agentRootEnvNode is! String ||
            !_envNamePattern.hasMatch(agentRootEnvNode))) {
      throw ConfigException(
        '$sourcePath.spec.agentRootEnv: must be an env var name '
        '([A-Za-z_][A-Za-z0-9_]*), got ${renderValue(agentRootEnvNode)}',
      );
    }

    final widenNode = spec['widenToDotParent'];
    if (widenNode != null && widenNode is! bool) {
      throw ConfigException(
        '$sourcePath.spec.widenToDotParent: must be a bool, '
        'got ${renderValue(widenNode)}',
      );
    }

    return HarnessSpec(
      name: name,
      description: description as String?,
      command: command,
      agentRoot: agentRoot,
      agentRootEnv: agentRootEnvNode as String?,
      widenToDotParent: widenNode as bool? ?? false,
      extraRead: _sanitizePathList(spec['extraRead'], '$sourcePath.spec.extraRead'),
      extraWrite: _sanitizePathList(spec['extraWrite'], '$sourcePath.spec.extraWrite'),
      network: HarnessNetwork.parse(spec['network'], '$sourcePath.spec.network'),
    );
  }

  /// Renders this spec back to canonical manifest yaml (used by
  /// `cuberun new`; the output must round-trip through [fromYamlText]).
  String toYamlText() {
    final b = StringBuffer();
    b.writeln('# cuberun harness manifest — strict schema (apiVersion cuberun/v1)');
    b.writeln('apiVersion: cuberun/v1');
    b.writeln('kind: Harness');
    b.writeln('metadata:');
    b.writeln('  name: $name');
    if (description != null) {
      b.writeln('  description: ${_quote(description!)}');
    }
    b.writeln('spec:');
    if (command.length == 1) {
      b.writeln('  command: ${_quote(command.first)}');
    } else {
      b.writeln('  command:');
      for (final c in command) {
        b.writeln('    - ${_quote(c)}');
      }
    }
    b.writeln('  agentRoot: ${_quote(agentRoot)}');
    if (agentRootEnv != null) {
      b.writeln('  agentRootEnv: $agentRootEnv');
    }
    if (widenToDotParent) {
      b.writeln('  widenToDotParent: true');
    }
    if (extraRead.isNotEmpty) {
      b.writeln('  extraRead:');
      for (final p in extraRead) {
        b.writeln('    - ${_quote(p)}');
      }
    }
    if (extraWrite.isNotEmpty) {
      b.writeln('  extraWrite:');
      for (final p in extraWrite) {
        b.writeln('    - ${_quote(p)}');
      }
    }
    b.writeln('  network: open');
    return b.toString();
  }

  static String _sanitizeArgvEntry(Object? v, String where) {
    if (v is! String || v.trim().isEmpty || v.contains('\x00')) {
      throw ConfigException('$where: must be a non-empty string without NUL');
    }
    return v;
  }

  static List<String> _sanitizePathList(Object? node, String where) {
    if (node == null) return const [];
    if (node is! YamlList) {
      throw ConfigException('$where: must be a list of paths, got ${node.runtimeType}');
    }
    return [
      for (var i = 0; i < node.length; i++)
        sanitizeManifestPath(node[i], '$where[$i]'),
    ];
  }

  static String _quote(String s) =>
      s.contains("'") ? '"${s.replaceAll('"', r'\"')}"' : "'$s'";
}

void _checkKeys(YamlMap node, Set<String> allowed, String where) {
  for (final key in node.keys) {
    if (key is! String || !allowed.contains(key)) {
      throw ConfigException(
        '$where.${key is String ? key : key.runtimeType}: unknown key '
        '(allowed: ${allowed.toList()..sort()})',
      );
    }
  }
}
