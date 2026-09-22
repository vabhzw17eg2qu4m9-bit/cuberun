/// Banner: the resolved-grants lines `launch`/`show` print. Pure
/// derivation from (resolved, runtime, key10) — extracted verbatim from
/// the CLI so unit tests pin banner truthfulness without importing
/// cli.dart (issue #69 AC4: the banner always describes the config that
/// staged and ran; loudness is added as warnings, never optimism).
library;

import 'resolver.dart';
import 'runtime.dart';

/// Builds the banner lines: header, source, rw, ro, denied, optional
/// `use`, then [warnings] (runtime + cache loudness) as `⚠` lines.
List<String> bannerLines({
  required ResolvedHarness resolved,
  required HarnessRuntime runtime,
  required String key10,
  String? profilePath,
  Iterable<String> warnings = const [],
}) {
  final src = resolved.path == null
      ? resolved.source.label
      : '${resolved.source.label} (${resolved.path})';
  return [
    '⛨ ${resolved.spec.name} under cube-sandbox '
        '(profile $key10${profilePath == null ? '' : ': $profilePath'})',
    '   source : $src',
    '   rw     : ${runtime.projDir} · ${runtime.agentRoot} · ${runtime.tmp}'
        '${runtime.extraWrite.isEmpty ? '' : ' · ${runtime.extraWrite.join(' · ')}'}',
    '   ro     : system dirs'
        '${runtime.runtimeDirs.isEmpty ? '' : ' · runtime (${runtime.runtimeDirs.join(' · ')})'}'
        '${runtime.extraRead.isEmpty ? '' : ' · ${runtime.extraRead.join(' · ')}'}',
    '   denied : /Users /private/var /Volumes /Network /home /net '
        '(except grants above — blanket read-deny unbuildable, E1) · '
        'all writes outside rw · network OPEN (cubes deny net inside)',
    if (runtime.services.isNotEmpty)
      '   use    : ${(runtime.services.toList()..sort()).join(', ')}',
    for (final w in [...runtime.warnings, ...warnings]) '⚠  $w',
  ];
}
