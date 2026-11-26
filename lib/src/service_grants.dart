/// Service grants: `--use-<service>` folds a service's state folders into
/// the resolved profile BEFORE the SBPL emit — read-only for
/// configs/credentials the service reads, rw only for its caches.
///
/// Pinned principle (GOAL v2): services GRANT FOLDERS, they never forbid
/// commands — a confined `gh`, `glab`, `npm` simply cannot reach anything
/// outside the union of its grants.
///
/// Determinism (E9): flags union + dedup; flag ORDER never changes the
/// emitted text (the union is what enters the profile, sorted at emit).
/// Unknown service fails closed, LOUD, with the catalog listed — a typo
/// must never degrade to "no grant".
library;

import 'exceptions.dart';
import 'paths.dart';
import 'service_profiles.dart';

/// One catalog entry: a service id and the folders it needs.
final class ServiceGrant {
  /// Creates a grant entry.
  const ServiceGrant(
    this.id, {
    required this.read,
    this.write = const [],
    this.description,
  });

  /// Catalog id used in `--use-<id>`.
  final String id;

  /// Read-only folders (lexical, `~` allowed).
  final List<String> read;

  /// Read-write folders (caches only — never configs/credentials).
  final List<String> write;

  /// One-line description for the catalog listing.
  final String? description;
}

/// The built-in service-grant catalog (core tier). REG pins this list:
/// a folder change without a GOAL revision is a red build.
const List<ServiceGrant> kServiceCatalog = <ServiceGrant>[
  ServiceGrant(
    'github',
    read: ['~/.config/gh', '~/.gitconfig'],
    description: 'gh config + token (hosts.yml, no Keychain) · git identity',
  ),
  ServiceGrant(
    'gitlab',
    read: ['~/.config/glab', '~/.gitconfig'],
    description: 'glab config · git identity (dedups with --use-github)',
  ),
  ServiceGrant(
    'nvm',
    read: ['~/.nvm'],
    description: 'node installs under ~/.nvm/versions/node/<v>',
  ),
  ServiceGrant(
    'uv',
    read: [],
    write: ['~/.cache/uv', '~/.local/share/uv'],
    description: 'uv cache + managed pythons (python/) & tools (tools/)',
  ),
];

/// Catalog ids in catalog order.
List<String> get serviceCatalogIds => [for (final g in kServiceCatalog) g.id];

/// Resolved folder grants for a set of `--use-*` flags: expanded, deduped,
/// sorted. [env] carries services.yaml env overlays for the confined
/// child; [warnings] carries E10 blocklisted-read acknowledgements (loud,
/// never silent) from config profiles.
final class ServiceGrantsResolved {
  /// Creates a resolved grant set.
  const ServiceGrantsResolved({
    required this.read,
    required this.write,
    required this.used,
    this.env = const {},
    this.warnings = const [],
  });

  /// Read-only folders (absolute, expanded).
  final List<String> read;

  /// Read-write folders (absolute, expanded).
  final List<String> write;

  /// The flag set that produced these grants (for banners/keying).
  final Set<String> used;

  /// Env overlay from config profiles (first occurrence wins), injected
  /// into the confined command's environment at launch.
  final Map<String, String> env;

  /// Non-fatal operator acknowledgements (config-profile blocklisted
  /// reads) — rendered in the banner.
  final List<String> warnings;
}

/// Resolves `--use-*` [flags] against the catalog first, then against
/// [profiles] (`~/.cube-sandbox/services.yaml`, issue #204) for ids the
/// catalog does not own — the catalog always wins on name collision.
/// Unknown ids (in NEITHER source) throw [ConfigException] listing the
/// catalog + discovered config profiles + the AGENTS.md pointer
/// (fail-closed, E9).
ServiceGrantsResolved resolveServiceGrants(
  Set<String> flags, {
  required String home,
  ServiceProfilesDoc? profiles,
}) {
  final selected = selectServiceProfiles(profiles, flags);
  _requireKnownIds(flags, selected, profiles);
  final read = <String>{};
  final write = <String>{};
  // Iterate the CATALOG order (not the flag order) so flag order cannot
  // change the union's construction — determinism regardless of input.
  for (final grant in kServiceCatalog) {
    if (!flags.contains(grant.id)) continue;
    read.addAll([for (final p in grant.read) expandTilde(p, home)]);
    write.addAll([for (final p in grant.write) expandTilde(p, home)]);
  }
  // Config profiles join the SAME stage, in sorted name order (E9).
  final config = _expandProfiles(selected, home);
  read.addAll(config.read);
  write.addAll(config.write);
  return ServiceGrantsResolved(
    read: read.toList()..sort(),
    write: write.toList()..sort(),
    used: Set.of(flags),
    env: Map.unmodifiable(config.env),
    warnings: List.unmodifiable(config.warnings),
  );
}

/// Fail-closed id validation: every flag must be a catalog id or a
/// selected config profile — a typo must never degrade to "no grant".
void _requireKnownIds(
  Set<String> flags,
  List<ServiceProfile> selected,
  ServiceProfilesDoc? profiles,
) {
  final catalogIds = serviceCatalogIds.toSet();
  for (final flag in flags) {
    if (catalogIds.contains(flag)) continue;
    if (selected.any((p) => p.name == flag)) continue;
    throw ConfigException(
      '--use-$flag: unknown service '
      '(catalog: ${serviceCatalogIds.join(', ')})'
      '${_configListing(profiles)} — custom grants live in '
      '$kServiceProfilesPath (see ~/.cube-sandbox/AGENTS.md, '
      '"Custom service profiles")',
    );
  }
}

/// Expands the selected config profiles: unions read/write, merges env
/// keys first-occurrence-wins, and applies the E10 per-direction
/// contract (env-knob verbatim): a config WRITE hit is rejected
/// outright; a config read hit is honored but lands in `warnings` —
/// never silent. (Built-in catalog paths are always clean, so any
/// violation necessarily comes from services.yaml.)
({
  Set<String> read,
  Set<String> write,
  Map<String, String> env,
  List<String> warnings,
})
_expandProfiles(List<ServiceProfile> selected, String home) {
  final read = <String>{};
  final write = <String>{};
  final env = <String, String>{};
  for (final p in selected) {
    read.addAll(p.read);
    write.addAll(p.write);
    for (final e in p.env.entries) {
      env.putIfAbsent(e.key, () => e.value);
    }
  }
  final writeViolations = ungrantableViolations(write.toList(), home);
  if (writeViolations.isNotEmpty) {
    throw ConfigException(
      '$kServiceProfilesPath carries ungrantable write path(s) '
      '${writeViolations.join(', ')} — writes to ~/.ssh, ~/.gnupg or '
      '~/Library/Keychains are never grantable (E10)',
    );
  }
  final warnings = [
    for (final v in ungrantableViolations(read.toList(), home))
      '$kServiceProfilesPath carries blocklisted read path $v — '
          'operator override honored, NEVER silent (E10)',
  ];
  return (read: read, write: write, env: env, warnings: warnings);
}

/// Names the config profiles a fail-closed error should list: the
/// discovered names, or the explicit absence of the file (the listing
/// must always answer "what DOES exist?").
String _configListing(ServiceProfilesDoc? profiles) => profiles == null
    ? '; no services.yaml found'
    : '; services.yaml: ${profiles.services.keys.toList()..sort()}';

/// Config profiles named by [flags] — non-built-in ids the doc owns, in
/// SORTED name order (E9: flag order never changes the union). Shadowed
/// names are skipped: the built-in catalog always wins.
List<ServiceProfile> selectServiceProfiles(
  ServiceProfilesDoc? doc,
  Set<String> flags,
) {
  if (doc == null) return const [];
  final catalogIds = serviceCatalogIds.toSet();
  final names = [
    for (final f in flags)
      if (!catalogIds.contains(f) && doc.services.containsKey(f)) f,
  ]..sort();
  return [for (final n in names) doc.services[n]!];
}

/// Home-relative roots that NO grant may ever touch (E10): `~/.ssh`,
/// `~/.gnupg`, `~/Library/Keychains` — plus their `/private` spellings.
const List<String> kUngrantableHomeSuffixes = <String>[
  '.ssh',
  '.gnupg',
  'Library/Keychains',
];

/// Returns the entries of [paths] that fall inside an ungrantable root
/// (both macOS spellings checked). Empty list = clean.
List<String> ungrantableViolations(List<String> paths, String home) {
  final blocked = _ungrantableRoots(home);
  return [
    for (final p in paths)
      if (blocked.any((b) => p == b || p.startsWith('$b/'))) p,
  ];
}

/// The E10 roots, both macOS spellings.
Set<String> _ungrantableRoots(String home) {
  final blocked = <String>{};
  for (final suffix in kUngrantableHomeSuffixes) {
    final root = '$home/$suffix';
    blocked.addAll(bothSpellingsOf(root));
  }
  return blocked;
}

/// Prefix-grant variant (issue #139): a `(prefix ...)` grant covers every
/// path sharing its string prefix, so it is ungrantable not only when it
/// IS or is under a blocked root, but when it would COVER one (a
/// `~/.ss` prefix grant would take in all of `~/.ssh`).
List<String> ungrantablePrefixViolations(List<String> paths, String home) {
  final blocked = _ungrantableRoots(home);
  return [
    for (final p in paths)
      if (blocked.any((b) => p == b || p.startsWith('$b/') || b.startsWith(p)))
        p,
  ];
}

/// macOS dual spellings: `/var <-> /private/var`, `/etc`, `/tmp`, and
/// `/Users <-> /private/Users` — BOTH must appear or the kernel spelling
/// escapes the rule (E2).
List<String> bothSpellingsOf(String p) {
  final out = <String>{p};
  for (final base in const ['/etc', '/tmp', '/var', '/Users']) {
    out.addAll(_privateSpellingPair(p, base));
  }
  return out.toList()..sort();
}

/// Both spellings of [p] for one `X <-> /private/X` prefix pair: adds
/// `/private<p>` when [p] is at or under [base], and the un-prefixed
/// spelling when [p] is at or under `/private[base]`.
List<String> _privateSpellingPair(String p, String base) {
  final out = <String>[];
  if (p == base || p.startsWith('$base/')) out.add('/private$p');
  final privateBase = '/private$base';
  if (p == privateBase || p.startsWith('$privateBase/')) {
    out.add(p.substring('/private'.length));
  }
  return out;
}
