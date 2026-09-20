/// `cuberun new`: scaffolds `.cuberun/<name>.yaml` that MUST round-trip
/// through the strict parser before landing on disk (AC8).
library;

import 'dart:io' as io;

import 'exceptions.dart';
import 'harness_manifest.dart';
import 'paths.dart';

/// Renders the scaffold, parse-verifies it (round-trip proof), then writes
/// `<projectDir>/.cuberun/<name>.yaml`. Returns the written path.
///
/// Throws [ConfigException] when [name]/[command]/[agentRoot] fail the
/// schema or when the target file already exists.
String scaffoldProfile({
  required String name,
  required String command,
  required String agentRoot,
  required String projectDir,
}) {
  if (!RegExp(r'^[a-z][a-z0-9-]*$').hasMatch(name)) {
    throw ConfigException(
      'new <name>: must match ^[a-z][a-z0-9-]*\$, got "$name"',
    );
  }
  if (command.trim().isEmpty || command.contains('\x00')) {
    throw ConfigException('--command: must be non-empty');
  }
  final root = sanitizeManifestPath(agentRoot, '--agent-root');

  final spec = HarnessSpec(name: name, command: [command], agentRoot: root);
  final text = spec.toYamlText();
  // Round-trip proof: the scaffold MUST parse through the strict parser.
  final reparsed = HarnessSpec.fromYamlText(text, sourcePath: '<scaffold:$name>');
  if (reparsed.command.join(' ') != command || reparsed.agentRoot != root) {
    throw ConfigException('scaffold round-trip mismatch (bug)');
  }

  final dir = io.Directory('$projectDir/.cuberun');
  dir.createSync(recursive: true);
  final file = io.File('${dir.path}/$name.yaml');
  if (file.existsSync()) {
    throw ConfigException('${file.path}: already exists (refusing to overwrite)');
  }
  file.writeAsStringSync(text);
  return file.path;
}
