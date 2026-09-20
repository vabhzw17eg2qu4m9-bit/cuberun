/// Configuration failures: strict-parse rejects, resolver misses, grant
/// violations. Loud by design — a typo must never degrade to "no grant"
/// or "no confinement" (fail-closed everywhere).
library;

/// A schema/resolve violation naming the YAML path (or flag/env source)
/// that caused it.
final class ConfigException implements Exception {
  /// Creates a config error with a fully-qualified source path prefix
  /// already embedded in [message].
  const ConfigException(this.message);

  /// Human-readable, source-named diagnostic (printed to stderr, exit 2).
  final String message;

  @override
  String toString() => 'ConfigException: $message';
}
