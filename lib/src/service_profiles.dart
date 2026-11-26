/// Service profiles (issue #204): ONE user-level services file
/// (`~/.cube-sandbox/services.yaml`) of named `--use-<name>` grant
/// profiles, mirroring the folder_groups.dart conventions — strict by
/// construction, error messages name the file AND line.
///
/// Schema: `apiVersion: cube-sandbox/v1` + `services:` map of
/// name -> {optional `description:`, `read:`/`write:` path lists,
/// `env:` map of NAME -> scalar}. The file is NEVER read unless a run
/// names a non-built-in `--use-*` id (the built-in catalog wins on name
/// collision — see service_grants.dart).
library;

import 'dart:io' as io;

import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'paths.dart';

/// The single user-level services file (lexical spelling).
const String kServiceProfilesPath = '~/.cube-sandbox/services.yaml';

/// Service-name charset, mirroring the folder-group discipline.
final RegExp _serviceName = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// Env-var name discipline (the injected key must be a legal identifier).
final RegExp _envName = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

/// One named profile: tilde-expanded absolute grant paths per direction
/// plus the env overlay injected into the confined command.
final class ServiceProfile {
  /// Creates a profile; empty lists/maps = no grants/vars.
  const ServiceProfile({
    required this.name,
    this.description,
    this.read = const [],
    this.write = const [],
    this.env = const {},
  });

  /// Profile name, `[a-z0-9][a-z0-9-]*` (enforced at parse).
  final String name;

  /// Optional one-liner for listings.
  final String? description;

  /// Read-only grants (absolute, `~` expanded against home).
  final List<String> read;

  /// Read-write grants (absolute, `~` expanded against home).
  final List<String> write;

  /// Env overlay (validated names, scalar values) for the confined child.
  final Map<String, String> env;
}

/// A parsed services document: name -> profile, in file order.
final class ServiceProfilesDoc {
  /// Creates a doc; [services] may be empty (valid no-op).
  const ServiceProfilesDoc(this.services);

  /// The defined profiles.
  final Map<String, ServiceProfile> services;
}

/// 1-based line of a yaml node's span, for file:line diagnostics.
int _lineOf(Object? node) => node is YamlNode ? node.span.start.line + 1 : 0;

/// Accepts yaml scalars (string/int/bool/double) as a string; null for
/// collections/null — env values and descriptions must be scalars.
String? _scalarString(Object? v) =>
    v is String || v is int || v is bool || v is double ? v.toString() : null;

/// Parses the services document. STRICT: any deviation throws
/// [ConfigException] naming [path], the offending LINE, and the YAML
/// path (`<path>:<line>: services.<name>.<key>: ...`).
ServiceProfilesDoc parseServiceProfiles(
  String text, {
  required String path,
  required String home,
}) {
  final doc = _loadDocument(text, path);
  _checkTopKeys(doc, path);
  return ServiceProfilesDoc(_parseServices(doc, path: path, home: home));
}

/// Loads + shape-checks the document root: valid yaml, non-empty, a map.
YamlMap _loadDocument(String text, String path) {
  final Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException catch (e) {
    throw ConfigException(
      '$path:${(e.span?.start.line ?? 0) + 1}: invalid yaml: ${e.message}',
    );
  }
  if (doc == null) {
    throw ConfigException(
      '$path: empty document (apiVersion: cube-sandbox/v1 required)',
    );
  }
  if (doc is! YamlMap) {
    throw ConfigException('$path: must be a map, got ${doc.runtimeType}');
  }
  return doc;
}

/// Top level allows only apiVersion + services, at ANY position. Nodes
/// (not values) so every error carries a line number.
void _checkTopKeys(YamlMap doc, String path) {
  for (final entry in doc.nodes.entries) {
    final v = entry.key.value;
    if (v is! String || (v != 'apiVersion' && v != 'services')) {
      throw ConfigException(
        '$path:${_lineOf(entry.key)}: ${renderValue(v)}: '
        'unknown key (allowed: [apiVersion, services])',
      );
    }
  }
  final apiVersion = doc.nodes['apiVersion'];
  if (apiVersion == null || apiVersion.value != 'cube-sandbox/v1') {
    throw ConfigException(
      '$path:${_lineOf(apiVersion ?? doc)}: apiVersion: must be '
      '"cube-sandbox/v1", got ${renderValue(apiVersion?.value)}',
    );
  }
}

/// Parses the `services:` node: absent/empty is a valid no-op; otherwise
/// a map of name -> profile body, names enforced per entry.
Map<String, ServiceProfile> _parseServices(
  YamlMap doc, {
  required String path,
  required String home,
}) {
  final servicesNode = doc.nodes['services'];
  if (servicesNode == null || servicesNode.value == null) {
    return const {};
  }
  if (servicesNode is! YamlMap) {
    throw ConfigException(
      '$path:${_lineOf(servicesNode)}: services: must be a map of '
      'services, got ${servicesNode.value.runtimeType}',
    );
  }
  final services = <String, ServiceProfile>{};
  for (final entry in servicesNode.nodes.entries) {
    final name = _serviceNameOf(entry.key, path);
    services[name] = _parseProfile(name, entry.value, path: path, home: home);
  }
  return services;
}

/// The map key must be a service name matching the charset.
String _serviceNameOf(YamlNode key, String path) {
  final name = key.value;
  if (name is! String || !_serviceName.hasMatch(name)) {
    throw ConfigException(
      '$path:${_lineOf(key)}: services.${renderValue(name)}: '
      'service name must match [a-z0-9][a-z0-9-]*',
    );
  }
  return name;
}

/// Parses one service body: map with optional
/// description:/read:/write:/env: keys only.
ServiceProfile _parseProfile(
  String name,
  Object? body, {
  required String path,
  required String home,
}) {
  if (body is! YamlMap) {
    throw ConfigException(
      '$path:${_lineOf(body)}: services.$name: must be a map with '
      'optional description:/read:/write:/env:, got ${body.runtimeType}',
    );
  }
  _checkBodyKeys(name, body, path);
  return ServiceProfile(
    name: name,
    description: _parseDescription(name, body, path),
    read: _parseDir(body, 'read', name, path: path, home: home),
    write: _parseDir(body, 'write', name, path: path, home: home),
    env: _parseEnv(body, name, path: path),
  );
}

/// The body map allows only description/read/write/env, at ANY position.
void _checkBodyKeys(String name, YamlMap body, String path) {
  for (final key in body.keys) {
    if (key is! String ||
        (key != 'description' &&
            key != 'read' &&
            key != 'write' &&
            key != 'env')) {
      throw ConfigException(
        '$path:${_lineOf(body.nodes[key])}: services.$name.$key: '
        'unknown key (allowed: [description, read, write, env])',
      );
    }
  }
}

/// The optional description: an absent/null node is no description; a
/// present one must be a scalar string.
String? _parseDescription(String name, YamlMap body, String path) {
  final node = body.nodes['description'];
  if (node == null || node.value == null) return null;
  final d = _scalarString(node.value);
  if (d == null) {
    throw ConfigException(
      '$path:${_lineOf(node)}: services.$name.description: '
      'must be a string, got ${node.value.runtimeType}',
    );
  }
  return d;
}

/// Parses one direction: optional list of sanitized, tilde-expanded paths.
List<String> _parseDir(
  YamlMap body,
  String dir,
  String name, {
  required String path,
  required String home,
}) {
  final node = body.nodes[dir];
  if (node == null || node.value == null) return const [];
  if (node is! YamlList) {
    throw ConfigException(
      '$path:${_lineOf(node)}: services.$name.$dir: must be a list of '
      'paths, got ${node.value.runtimeType}',
    );
  }
  return [
    for (var i = 0; i < node.length; i++)
      (() {
        final item = node.nodes[i];
        final v = item.value;
        final line = _lineOf(item);
        return expandTilde(
          sanitizeManifestPath(v, '$path:$line: services.$name.$dir[$i]'),
          home,
        );
      })(),
  ];
}

/// Parses the env overlay: map of legal identifier -> scalar string.
Map<String, String> _parseEnv(
  YamlMap body,
  String name, {
  required String path,
}) {
  final node = body.nodes['env'];
  if (node == null || node.value == null) return const {};
  if (node is! YamlMap) {
    throw ConfigException(
      '$path:${_lineOf(node)}: services.$name.env: must be a map of '
      'NAME: value, got ${node.value.runtimeType}',
    );
  }
  final env = <String, String>{};
  for (final entry in node.nodes.entries) {
    final key = entry.key;
    final envName = key.value;
    if (envName is! String || !_envName.hasMatch(envName)) {
      throw ConfigException(
        '$path:${_lineOf(key)}: services.$name.env.'
        '${renderValue(envName)}: env name must match '
        '[A-Za-z_][A-Za-z0-9_]*',
      );
    }
    final valueNode = entry.value;
    final value = _scalarString(valueNode.value);
    if (value == null) {
      throw ConfigException(
        '$path:${_lineOf(valueNode)}: services.$name.env.$envName: '
        'must be a scalar value, got ${valueNode.value.runtimeType}',
      );
    }
    env[envName] = value;
  }
  return env;
}

/// Loads + parses [kServiceProfilesPath] under [home]. Returns null when
/// the file does not exist — callers decide the policy (an unknown
/// `--use-*` id → fail-closed listing; built-in-only runs never read it).
ServiceProfilesDoc? loadServiceProfiles({required String home}) {
  final filePath = expandTilde(kServiceProfilesPath, home);
  final file = io.File(filePath);
  if (!file.existsSync()) return null;
  return parseServiceProfiles(
    file.readAsStringSync(),
    path: filePath,
    home: home,
  );
}

/// Deterministic provenance text for a selection: profile names + resolved
/// entries + env KEYS (values never — the `.src` stamp must stay
/// secret-free, matching the byte-scan contract). Folded into the `.src`
/// stamp so cache loudness stays truthful (issue #69) when services.yaml
/// changes under the same key10.
String serviceProfilesStamp(List<ServiceProfile> selected) => [
  for (final p in selected)
    'services.${p.name}: '
        'read=[${p.read.join(', ')}] '
        'write=[${p.write.join(', ')}] '
        'env=[${p.env.keys.join(', ')}]',
].join('; ');
