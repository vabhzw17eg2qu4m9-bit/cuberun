/// HarnessResolver: `--file` > project `.cuberun/` > user `~/.cuberun/` >
/// preset (AC3). Resolution keys on the FILENAME stem, so what lists is
/// what launches even when `metadata.name` differs (E8).
library;

import 'dart:io' as io;

import 'exceptions.dart';
import 'harness_manifest.dart';
import 'presets.dart';

/// Where a harness spec came from.
enum HarnessSource {
  /// Explicit `--file` override.
  file('file'),

  /// `<cwd>/.cuberun/<name>.yaml`.
  project('.cuberun/ (project)'),

  /// `~/.cuberun/<name>.yaml`.
  user('~/.cuberun/ (user)'),

  /// Built-in preset manifest text.
  preset('preset');

  const HarnessSource(this.label);

  /// Display label for `list`/`show`.
  final String label;
}

/// A resolved harness + its provenance.
final class ResolvedHarness {
  /// Creates a resolution result.
  const ResolvedHarness({required this.spec, required this.source, this.path});

  /// The parsed spec (name keyed on the filename stem for file sources).
  final HarnessSpec spec;

  /// Where it came from.
  final HarnessSource source;

  /// File path (null for presets).
  final String? path;
}

/// One `cuberun list` row.
final class ProfileListing {
  /// Creates a row.
  const ProfileListing({required this.stem, required this.source, required this.description});

  /// The name resolution keys on (filename stem or preset id).
  final String stem;

  /// Provenance.
  final HarnessSource source;

  /// `metadata.description` when present.
  final String? description;
}

final class _Scanned {
  const _Scanned(this.stem, this.description);
  final String stem;
  final String? description;
}

final class HarnessResolver {
  /// Creates a resolver rooted at [cwd]/[home].
  const HarnessResolver({required this.cwd, required this.home});

  /// Project directory (`.cuberun/` lives here).
  final String cwd;

  /// User home (`~/.cuberun/` lives here).
  final String home;

  /// Resolves [name] (or an explicit [file]) through the precedence
  /// chain; throws [ConfigException] listing every location + presets on
  /// a miss (AC3).
  ResolvedHarness resolve(String name, {String? file}) {
    if (file != null) {
      final f = io.File(file);
      if (!f.existsSync()) {
        throw ConfigException('--file $file: not found');
      }
      return ResolvedHarness(
        spec: _parseFile(f),
        source: HarnessSource.file,
        path: file,
      );
    }
    final project = io.File('$cwd/.cuberun/$name.yaml');
    if (project.existsSync()) {
      return ResolvedHarness(
        spec: _parseFile(project),
        source: HarnessSource.project,
        path: project.path,
      );
    }
    final user = io.File('$home/.cuberun/$name.yaml');
    if (user.existsSync()) {
      return ResolvedHarness(
        spec: _parseFile(user),
        source: HarnessSource.user,
        path: user.path,
      );
    }
    if (HarnessPresets.has(name)) {
      return ResolvedHarness(
        spec: HarnessPresets.load(name),
        source: HarnessSource.preset,
      );
    }
    throw ConfigException(
      "profile '$name' not found — looked: --file (none), "
      '${project.path}, ${user.path}, '
      'presets(${HarnessPresets.ids.join(', ')})',
    );
  }

  /// Lists every profile: presets + project files + user files, each row
  /// labeled with its source (stems may repeat across sources; precedence
  /// at resolve time decides which one launches).
  List<ProfileListing> list() {
    final out = <ProfileListing>[
      for (final id in HarnessPresets.ids)
        ProfileListing(
          stem: id,
          source: HarnessSource.preset,
          description: HarnessPresets.load(id).description,
        ),
    ];
    void scan(String dirPath, HarnessSource source) {
      for (final e in _scan(dirPath)) {
        out.add(ProfileListing(
          stem: e.stem,
          source: source,
          description: e.description,
        ));
      }
    }

    scan('$cwd/.cuberun', HarnessSource.project);
    scan('$home/.cuberun', HarnessSource.user);
    return out;
  }

  /// Parses a manifest file, keying the spec name on the FILENAME stem
  /// (E8); strict-parse failures name the file in the error.
  HarnessSpec _parseFile(io.File f) {
    final stem = f.path.split('/').last.replaceAll(RegExp(r'\.yaml$'), '');
    final text = f.readAsStringSync();
    final spec = HarnessSpec.fromYamlText(text, sourcePath: f.path);
    if (spec.name == stem) return spec;
    // E8: display/resolution keys on the stem, not metadata.name.
    return HarnessSpec(
      name: stem,
      description: spec.description,
      command: spec.command,
      agentRoot: spec.agentRoot,
      agentRootEnv: spec.agentRootEnv,
      widenToDotParent: spec.widenToDotParent,
      extraRead: spec.extraRead,
      extraWrite: spec.extraWrite,
      network: spec.network,
    );
  }

  static List<_Scanned> _scan(String dirPath) {
    final dir = io.Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final out = <_Scanned>[];
    final names = <String>[];
    for (final e in dir.listSync()) {
      final base = e.path.split('/').last;
      if (base.startsWith('.') || !base.endsWith('.yaml')) continue;
      names.add(base);
    }
    names.sort();
    for (final base in names) {
      final stem = base.replaceAll(RegExp(r'\.yaml$'), '');
      try {
        final spec = HarnessSpec.fromYamlText(
          io.File('$dirPath/$base').readAsStringSync(),
          sourcePath: '$dirPath/$base',
        );
        out.add(_Scanned(stem, spec.description));
      } on ConfigException {
        // List what parses; the broken file fails loudly when launched.
        out.add(_Scanned(stem, '<parse error — run to see diagnostic>'));
      }
    }
    return out;
  }
}
