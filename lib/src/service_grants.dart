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

/// One catalog entry: a service id and the folders it needs.
final class ServiceGrant {
  /// Creates a grant entry.
  const ServiceGrant(this.id, {required this.read, this.write = const [], this.description});

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
];

/// Catalog ids in catalog order.
List<String> get serviceCatalogIds =>
    [for (final g in kServiceCatalog) g.id];

/// Resolved folder grants for a set of `--use-*` flags: expanded, deduped,
/// sorted.
final class ServiceGrantsResolved {
  /// Creates a resolved grant set.
  const ServiceGrantsResolved({required this.read, required this.write, required this.used});

  /// Read-only folders (absolute, expanded).
  final List<String> read;

  /// Read-write folders (absolute, expanded).
  final List<String> write;

  /// The flag set that produced these grants (for banners/keying).
  final Set<String> used;
}

/// Resolves `--use-*` [flags] against the catalog. Unknown ids throw
/// [ConfigException] listing the whole catalog (fail-closed, E9).
ServiceGrantsResolved resolveServiceGrants(Set<String> flags, {required String home}) {
  final byId = {for (final g in kServiceCatalog) g.id: g};
  for (final flag in flags) {
    if (!byId.containsKey(flag)) {
      throw ConfigException(
        '--use-$flag: unknown service (catalog: ${serviceCatalogIds.join(', ')})',
      );
    }
  }
  final read = <String>{};
  final write = <String>{};
  // Iterate the CATALOG order (not the flag order) so flag order cannot
  // change the union's construction — determinism regardless of input.
  for (final grant in kServiceCatalog) {
    if (!flags.contains(grant.id)) continue;
    for (final p in grant.read) {
      read.add(expandTilde(p, home));
    }
    for (final p in grant.write) {
      write.add(expandTilde(p, home));
    }
  }
  return ServiceGrantsResolved(
    read: read.toList()..sort(),
    write: write.toList()..sort(),
    used: Set.of(flags),
  );
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
  final blocked = <String>{};
  for (final suffix in kUngrantableHomeSuffixes) {
    final root = '$home/$suffix';
    blocked.addAll(bothSpellingsOf(root));
  }
  return [
    for (final p in paths)
      if (blocked.any((b) => p == b || p.startsWith('$b/'))) p,
  ];
}

/// macOS dual spellings: `/var <-> /private/var`, `/etc`, `/tmp`, and
/// `/Users <-> /private/Users` — BOTH must appear or the kernel spelling
/// escapes the rule (E2).
List<String> bothSpellingsOf(String p) {
  String priv(String x) => '/private$x';
  final out = <String>{p};
  for (final base in ['/etc', '/tmp', '/var']) {
    if (p == base || p.startsWith('$base/')) out.add(priv(p));
    final pb = priv(base);
    if (p == pb || p.startsWith('$pb/')) out.add(p.substring('/private'.length));
  }
  if (p == '/Users' || p.startsWith('/Users/')) out.add(priv(p));
  const pu = '/private/Users';
  if (p == pu || p.startsWith('$pu/')) out.add(p.substring('/private'.length));
  return out.toList()..sort();
}
