/// CachePolicy: provenance + shadow loudness for the staged profile cache
/// (issue #69). key10 fingerprints the EMITTED text only, so a cached
/// `.sb` never recorded WHICH source it was built from — the missing link
/// that let an edited manifest resolve to a stale copy silently ("same
/// key, stale grants"). Two fixes, both loud:
///
/// - every staged profile keeps a `.src` provenance stamp beside it;
///   re-staging the same key10 from a different source returns the
///   previous stamp so the CLI can warn (rebuild made observable);
/// - `shadowedCopies` names any DIFFERING same-stem copy in the other
///   precedence-chain locations, so "I edited the manifest" can never be
///   silently ignored — the loser is printed, the winner is in `source :`.
///
/// Byte-stability is untouched: identical source ⇒ identical stamp ⇒ no
/// rewrite, no churn (the `.sb` itself stays mtime-stable, E7).
library;

import 'dart:convert' show utf8;
import 'dart:io' as io;

import 'package:crypto/crypto.dart' show sha256;

import 'resolver.dart';
import 'sbpl.dart';
import 'stage.dart';

/// Provenance of a resolved source: content fingerprint + human detail.
typedef SourceStamp = ({String fp, String detail});

/// Fingerprints the RESOLVED SOURCE (label, path, raw manifest text).
/// Distinct from key10 (which fingerprints the emit): two sources that
/// emit identically still carry different stamps, so the cache can say
/// so. Pure and deterministic.
SourceStamp sourceStamp(ResolvedHarness resolved) {
  final label = resolved.source.label;
  final path = resolved.path ?? '-';
  final fp = sha256
      .convert(utf8.encode('$label\n$path\n${resolved.sourceText ?? ''}'))
      .toString();
  final detail = resolved.path == null ? label : '$label (${resolved.path})';
  return (fp: fp, detail: detail);
}

/// Sidecar holding a staged profile's provenance stamp.
String sidecarPath(String cacheDir, String key10) =>
    '$cacheDir/harness-$key10.src';

/// Reads a staged provenance stamp; null when absent, empty or
/// unreadable (a dead sidecar must never crash a launch).
SourceStamp? readSourceStamp(String cacheDir, String key10) {
  final f = io.File(sidecarPath(cacheDir, key10));
  if (!f.existsSync()) return null;
  final List<String> parts;
  try {
    parts = f.readAsStringSync().trim().split('  ');
  } on io.FileSystemException {
    return null;
  } on FormatException {
    // Non-UTF-8 garbage: as unreadable — fail-closed rebuild, never a
    // raw crash (issue #69 AC6).
    return null;
  }
  if (parts.isEmpty || parts.first.isEmpty) return null;
  return (fp: parts.first, detail: parts.skip(1).join('  '));
}

/// Writes [stamp] beside the staged profile.
void writeSourceStamp(String cacheDir, String key10, SourceStamp stamp) {
  io.File(
    sidecarPath(cacheDir, key10),
  ).writeAsStringSync('${stamp.fp}  ${stamp.detail}\n', flush: true);
}

/// Stages [profile] and records [resolved]'s provenance beside it.
///
/// Returns the PREVIOUS stamp when it differs from the current source
/// (caller warns loudly — the cache was re-tied to a changed source);
/// null when absent (first stage or legacy cache adoption) or identical
/// (byte-stable no-op, sidecar not rewritten).
SourceStamp? stageWithProvenance({
  required String cacheDir,
  required SbplProfile profile,
  required ResolvedHarness resolved,
}) {
  final stamp = sourceStamp(resolved);
  final previous = readSourceStamp(cacheDir, profile.key10);
  stageProfile(cacheDir: cacheDir, text: profile.text, key10: profile.key10);
  if (previous == null || previous.fp != stamp.fp) {
    writeSourceStamp(cacheDir, profile.key10, stamp);
  }
  if (previous == null || previous.fp == stamp.fp) return null;
  return previous;
}

/// Same-stem copies in the OTHER chain locations whose content differs
/// from the winner (E1 loudness). Missing files and identical content
/// are not shadows — only DRIFT is loud.
List<String> shadowedCopies({
  required String stem,
  required String? winnerPath,
  required String? winnerText,
  required String projectDir,
  required String userDir,
}) {
  final shadows = <String>[];
  for (final dir in [projectDir, userDir]) {
    final p = '$dir/$stem.yaml';
    if (p == winnerPath) continue;
    final f = io.File(p);
    if (!f.existsSync()) continue;
    if (winnerText != null && f.readAsStringSync() == winnerText) continue;
    shadows.add(p);
  }
  return shadows;
}

/// Banner warnings naming each shadowed same-stem copy of [resolved]
/// (issue #69 AC4): the losing path, the winning one, no optimism.
List<String> shadowWarnings(
  ResolvedHarness resolved, {
  required String projectDir,
  required String userDir,
}) => [
  for (final p in shadowedCopies(
    stem: resolved.spec.name,
    winnerPath: resolved.path,
    winnerText: resolved.sourceText,
    projectDir: projectDir,
    userDir: userDir,
  ))
    'same-stem profile shadowed: $p differs and does NOT launch — '
        'the launcher resolves '
        '${resolved.path ?? resolved.source.label} (first hit wins); '
        'edit the winning file or remove the stale copy',
];
