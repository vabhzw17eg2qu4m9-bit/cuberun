/// Folder groups (issue #101): ONE user-level groups file
/// (`~/.cube-sandbox/folders.yaml`) of named read/write folder-grant
/// groups, selected per run via `--folders <group[,group...]>` layered
/// over whichever profile resolves.
///
/// Strict by construction: any schema deviation — wrong apiVersion,
/// unknown key at any level, manifest-only keys, bad group name,
/// wrong value type — is a [ConfigException] naming the file and the
/// offending YAML path (exit 2). The file is NEVER read unless the run
/// explicitly passes `--folders`; file presence alone grants nothing.
library;

import 'dart:io' as io;

import 'package:yaml/yaml.dart';

import 'exceptions.dart';
import 'paths.dart';
import 'service_grants.dart';

/// The single user-level groups file (lexical spelling).
const String kFolderGroupsPath = '~/.cube-sandbox/folders.yaml';

/// Group-name charset, mirroring the preset-name discipline.
final RegExp _groupName = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// One named group: tilde-expanded absolute grant paths per direction.
final class FolderGroup {
  /// Creates a group; empty lists = no grants in that direction.
  const FolderGroup({
    required this.name,
    this.read = const [],
    this.write = const [],
  });

  /// Group name, `[a-z0-9][a-z0-9-]*` (enforced at parse).
  final String name;

  /// Read-only grants (absolute, `~` expanded against home).
  final List<String> read;

  /// Read-write grants (absolute, `~` expanded against home).
  final List<String> write;
}

/// A parsed groups document: name → group, in file order.
final class FolderGroupsDoc {
  /// Creates a doc; [groups] may be empty (valid no-op).
  const FolderGroupsDoc(this.groups);

  /// The defined groups.
  final Map<String, FolderGroup> groups;
}

/// A resolved `--folders` selection: per-direction unions, first
/// occurrence wins, plus the blocklisted-read warnings (honored, loud).
final class SelectedFolderGroups {
  /// Creates a selection result.
  const SelectedFolderGroups({
    required this.groups,
    required this.read,
    required this.write,
    required this.warnings,
  });

  /// Selected groups in selection order (names deduped).
  final List<FolderGroup> groups;

  /// Read grants union, dedup first-occurrence-wins.
  final List<String> read;

  /// Write grants union, dedup first-occurrence-wins.
  final List<String> write;

  /// Blocklisted-read acknowledgements — rendered in the banner.
  final List<String> warnings;
}

/// Parses the groups document. STRICT: any deviation throws
/// [ConfigException] naming [path] and the offending YAML path.
FolderGroupsDoc parseFolderGroups(
  String text, {
  required String path,
  required String home,
}) {
  final doc = _loadDocument(text, path);
  _checkTopKeys(doc, path);
  if (doc['apiVersion'] != 'cube-sandbox/v1') {
    throw ConfigException(
      '$path: apiVersion: must be "cube-sandbox/v1", '
      'got ${renderValue(doc['apiVersion'])}',
    );
  }

  final groupsNode = doc['groups'];
  if (groupsNode == null) return const FolderGroupsDoc({});
  if (groupsNode is! YamlMap) {
    throw ConfigException(
      '$path: groups: must be a map of groups, got ${groupsNode.runtimeType}',
    );
  }

  final groups = <String, FolderGroup>{};
  for (final entry in groupsNode.entries) {
    final name = entry.key;
    if (name is! String || !_groupName.hasMatch(name)) {
      throw ConfigException(
        '$path: groups.${_keyName(name)}: '
        'group name must match [a-z0-9][a-z0-9-]*',
      );
    }
    groups[name] = _parseGroup(name, entry.value, path: path, home: home);
  }
  return FolderGroupsDoc(groups);
}

/// Renders an error-message key: names strings, types anything else.
String _keyName(Object? key) => key is String ? key : '${key.runtimeType}';

/// Loads + shape-checks the document root: valid yaml, non-empty, a map.
YamlMap _loadDocument(String text, String path) {
  final Object? doc;
  try {
    doc = loadYaml(text);
  } on YamlException catch (e) {
    throw ConfigException('$path: invalid yaml: ${e.message}');
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

/// Top level allows only apiVersion + groups, at ANY position.
void _checkTopKeys(YamlMap doc, String path) {
  for (final key in doc.keys) {
    if (key is! String || (key != 'apiVersion' && key != 'groups')) {
      throw ConfigException(
        '$path.${_keyName(key)}: unknown key '
        '(allowed: [apiVersion, groups])',
      );
    }
  }
}

/// Parses one group body: map with optional read:/write: keys only.
FolderGroup _parseGroup(
  String name,
  Object? body, {
  required String path,
  required String home,
}) {
  if (body is! YamlMap) {
    throw ConfigException(
      '$path: groups.$name: must be a map with optional read:/write:, '
      'got ${body.runtimeType}',
    );
  }
  for (final key in body.keys) {
    if (key is! String || (key != 'read' && key != 'write')) {
      throw ConfigException(
        '$path: groups.$name.${_keyName(key)}: '
        'unknown key (allowed: [read, write])',
      );
    }
  }
  return FolderGroup(
    name: name,
    read: _parseDir(body, 'read', name, path: path, home: home),
    write: _parseDir(body, 'write', name, path: path, home: home),
  );
}

/// Parses one direction: optional list of sanitized, tilde-expanded paths.
List<String> _parseDir(
  YamlMap body,
  String dir,
  String name, {
  required String path,
  required String home,
}) {
  final node = body[dir];
  if (node == null) return const [];
  if (node is! YamlList) {
    throw ConfigException(
      '$path: groups.$name.$dir: must be a list of paths, '
      'got ${node.runtimeType}',
    );
  }
  return [
    for (var i = 0; i < node.length; i++)
      expandTilde(
        sanitizeManifestPath(node[i], '$path.groups.$name.$dir[$i]'),
        home,
      ),
  ];
}

/// Loads + parses [kFolderGroupsPath] under [home]. Returns null when the
/// file does not exist — callers decide the policy (`--folders` used →
/// exit 2; flag unused → the file is never read).
FolderGroupsDoc? loadFolderGroups({required String home}) {
  final path = expandTilde(kFolderGroupsPath, home);
  final file = io.File(path);
  if (!file.existsSync()) return null;
  return parseFolderGroups(file.readAsStringSync(), path: path, home: home);
}

/// Parses the `--folders` value tokens: comma lists, occurrences
/// accumulate, order preserved, names dedup first-wins. Any element not
/// matching the group-name charset (empty element, trailing comma,
/// whitespace) is a [UsageException] — shape only, no file lookup here.
List<String> parseFolderSelection(Iterable<String> tokens) {
  final out = <String>[];
  for (final token in tokens) {
    for (final element in token.split(',')) {
      if (!_groupName.hasMatch(element)) {
        throw UsageException(
          '--folders: malformed group name ${renderValue(element)} '
          '(expected [a-z0-9][a-z0-9-]*, comma-separated)',
        );
      }
      if (!out.contains(element)) out.add(element);
    }
  }
  return out;
}

/// Resolves [selection] against [doc]: per-direction union, dedup
/// first-occurrence-wins (across selected groups). Unknown group →
/// [ConfigException] naming the group AND the file. Blocklist per
/// direction, env-knob contract verbatim (E10): a write hit throws; a
/// read hit is honored and lands in `warnings` (never silent).
SelectedFolderGroups resolveFolderGroups(
  FolderGroupsDoc doc,
  List<String> selection, {
  required String home,
}) {
  final unknown = [
    for (final s in selection)
      if (!doc.groups.containsKey(s)) s,
  ];
  if (unknown.isNotEmpty) {
    throw ConfigException(
      '--folders: unknown group(s) ${unknown.map(renderValue).join(', ')} '
      'in ${expandTilde(kFolderGroupsPath, home)} '
      '(defined: ${doc.groups.keys.toList()..sort()})',
    );
  }

  final selected = [for (final s in selection) doc.groups[s]!];
  final read = <String>[];
  final write = <String>[];
  for (final g in selected) {
    for (final p in g.read) {
      if (!read.contains(p)) read.add(p);
    }
    for (final p in g.write) {
      if (!write.contains(p)) write.add(p);
    }
  }

  final writeViolations = ungrantableViolations(write, home);
  if (writeViolations.isNotEmpty) {
    throw ConfigException(
      '--folders carries ungrantable write path(s) '
      '${writeViolations.join(', ')} — writes to ~/.ssh, ~/.gnupg or '
      '~/Library/Keychains are never grantable (E10)',
    );
  }
  final warnings = [
    for (final v in ungrantableViolations(read, home))
      '--folders carries blocklisted read path $v — operator override '
          'honored, NEVER silent (E10)',
  ];
  return SelectedFolderGroups(
    groups: selected,
    read: read,
    write: write,
    warnings: warnings,
  );
}

/// Deterministic provenance text for a selection: group names + resolved
/// entries — folded into the `.src` stamp so cache loudness stays
/// truthful (issue #69) when a selection changes.
String folderGroupsStamp(List<FolderGroup> selected) => [
  for (final g in selected)
    'folders.${g.name}: read=[${g.read.join(', ')}] write=[${g.write.join(', ')}]',
].join('; ');
