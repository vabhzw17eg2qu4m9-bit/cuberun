/// Shared path helpers: tilde expansion and manifest-path sanitation.
///
/// Sanitation is the E4 seam: every path that can end up inside an SBPL
/// literal goes through [sanitizeManifestPath] FIRST — quotes, newlines
/// and `..` climbs are impossible-by-construction, never escaped at emit.
library;

import 'exceptions.dart';

/// Expands a leading `~` to [home] (`~` alone, or `~/rest`). Anything else
/// is returned unchanged.
String expandTilde(String path, String home) {
  if (path == '~') return home;
  if (path.startsWith('~/')) return '$home${path.substring(1)}';
  return path;
}

/// Renders a yaml value for error messages: strings quoted, others bare.
String renderValue(Object? v) => v is String ? '"$v"' : '$v';

void _requireNonEmpty(String p, String where) {
  if (p.trim().isEmpty) {
    throw ConfigException('$where: must be a non-empty path');
  }
}

void _requireNoForbiddenChars(String p, String where) {
  if (p.contains('"') ||
      p.contains('\n') ||
      p.contains('\r') ||
      p.contains('\x00')) {
    throw ConfigException(
      '$where: forbidden character (quote/newline/NUL) in ${renderValue(p)}',
    );
  }
}

void _requireRooted(String p, String where) {
  final tildeOk = p == '~' || p.startsWith('~/');
  if (!p.startsWith('/') && !tildeOk) {
    throw ConfigException(
      '$where: must be absolute or ~/-prefixed, got ${renderValue(p)}',
    );
  }
}

void _requireNoDotDotSegments(String p, String where) {
  for (final segment in p.split('/')) {
    if (segment == '..') {
      throw ConfigException(
        '$where: ".." climbs are not allowed in ${renderValue(p)}',
      );
    }
  }
}

void _requireNoTrailingSlash(String p, String where) {
  if (p.length > 1 && p.endsWith('/')) {
    throw ConfigException(
      '$where: trailing "/" not allowed in ${renderValue(p)}',
    );
  }
}

/// Validates a declarative path (manifest `agentRoot`, `extraRead`,
/// `extraWrite`, service grants): non-empty, absolute or `~/`-prefixed,
/// no `"`, newlines, NUL, no `.`/`..` segments, no trailing `/`.
///
/// Returns the path unchanged (lexical — expansion happens at runtime
/// resolve). Throws [ConfigException] naming [where] on any violation.
String sanitizeManifestPath(Object? value, String where) {
  if (value is! String) {
    throw ConfigException(
      '$where: must be a path string, got ${value.runtimeType}',
    );
  }
  final p = value;
  _requireNonEmpty(p, where);
  _requireNoForbiddenChars(p, where);
  _requireRooted(p, where);
  _requireNoDotDotSegments(p, where);
  _requireNoTrailingSlash(p, where);
  return p;
}

/// Splits a colon-separated env-knob value (`CUBE_SANDBOX_EXTRA_READ` /
/// `CUBE_SANDBOX_EXTRA_WRITE`): trims, drops empties, expands `~` against
/// [home]. Returns `[]` for null/empty.
List<String> parseEnvPathList(String? value, String home) {
  if (value == null || value.trim().isEmpty) return const [];
  return value
      .split(':')
      .map((s) => expandTilde(s.trim(), home))
      .where((s) => s.isNotEmpty)
      .toList();
}
