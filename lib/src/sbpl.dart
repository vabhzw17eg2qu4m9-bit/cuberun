/// SbplProfile: deterministic SBPL text from a resolved [HarnessRuntime].
///
/// Semantics ported verbatim from the proven PoC launchers
/// (scripts/cube-pi.ts / cube-omp.ts in pi-vs-claude-code):
///
/// - `(version 1)` `(allow default)` `(allow network*)` — network is OPEN
///   at Layer 0 (deliberate, E1: SBPL remote filters take IP literals
///   only, LLM endpoints sit on rotating CDN IPs; per-task denies are the
///   inner cubes' job).
/// - writes deny-by-default (bare deny), allowed only for: project dir,
///   agent root, realpath($TMPDIR), extraWrite, /dev/null, /dev/fd.
/// - reads: curated denies over user-data roots (BOTH macOS spellings,
///   E2) with metadata re-allows so path resolution lives (a bare
///   `(deny file-read*)` makes the SBPL compiler ABORT — E1); system
///   dirs stay readable by design.
/// - rules sorted by (path length, verb, kind, path) within each section,
///   writes section first — last-match-wins means more specific paths win.
/// - key10 = first 10 hex of md5(text): identical facts => identical text
///   => identical key (AC4); ANY grant change => different key.
library;

import 'dart:convert' as convert;

import 'package:crypto/crypto.dart';

import 'runtime.dart';
import 'service_grants.dart';

/// User-data roots denied for reads (both spellings emitted — E2).
const List<String> kReadDenyRoots = <String>[
  '/Users', // home dirs — all of them (secrets, dotfiles, Documents…)
  '/private/var', // system state, other users' tmp (/var <-> /private/var)
  '/Volumes', // external/mounted disks
  '/Network',
  '/home',
  '/net', // autofs mounts
];

/// Re-allows under the deny roots that the system needs to function.
const List<String> kReadSystemReallows = <String>[
  '/private/var/db/dyld', // dyld shared cache — exec of system binaries
  '/private/var/run', // resolv.conf symlink target + mDNSResponder socket
];

enum _Verb { allow, deny }

enum _Kind { bare, literal, subpath }

final class _Rule {
  const _Rule(this.verb, this.kind, this.path, {this.metadata = false});

  final _Verb verb;
  final _Kind kind;
  final String path;
  final bool metadata; // file-read-metadata instead of file-read*
}

/// Lexicographic sort key: bare rules first (length -1), then path length,
/// verb (deny < allow), kind (literal < subpath), finally path text.
List<Comparable<Object?>> _sortKey(_Rule r) => <Comparable<Object?>>[
  r.kind == _Kind.bare ? -1 : r.path.length,
  r.verb == _Verb.deny ? 0 : 1,
  r.kind == _Kind.literal ? 0 : 1,
  r.path,
];

int _compare(_Rule a, _Rule b) {
  final ka = _sortKey(a);
  final kb = _sortKey(b);
  for (var i = 0; i < ka.length; i++) {
    final c = ka[i].compareTo(kb[i]);
    if (c != 0) return c;
  }
  return 0;
}

String _emit(_Rule r, String op) {
  if (r.kind == _Kind.bare) {
    return '(${r.verb.name} ${r.metadata ? 'file-read-metadata' : op})';
  }
  final arg = r.kind == _Kind.literal
      ? '(literal "${r.path}")'
      : '(subpath "${r.path}")';
  return '(${r.verb.name} ${r.metadata ? 'file-read-metadata' : op} $arg)';
}

/// The emitted profile: deterministic text + its content key.
final class SbplProfile {
  /// Creates a profile result.
  const SbplProfile({required this.text, required this.key10});

  /// Full SBPL document text.
  final String text;

  /// First 10 hex chars of md5(text) — the content-address key.
  final String key10;
}

/// Emits the deterministic SBPL profile for [runtime].
SbplProfile emitProfile(HarnessRuntime runtime) {
  final lines = <String>['(version 1)', '(allow default)', '(allow network*)'];

  // --- writes: bare deny, then explicit allows.
  final writes = <_Rule>[
    const _Rule(_Verb.deny, _Kind.bare, ''),
    const _Rule(_Verb.allow, _Kind.literal, '/dev/null'),
    const _Rule(_Verb.allow, _Kind.subpath, '/dev/fd'),
    _Rule(_Verb.allow, _Kind.subpath, runtime.projDir),
    _Rule(_Verb.allow, _Kind.subpath, runtime.agentRoot),
    _Rule(_Verb.allow, _Kind.subpath, runtime.tmp),
    for (final p in runtime.extraWrite) _Rule(_Verb.allow, _Kind.subpath, p),
  ];

  // --- reads: curated denies + metadata re-allows + grant re-allows.
  final reads = <_Rule>[];
  for (final root in kReadDenyRoots) {
    for (final p in bothSpellingsOf(root)) {
      reads.add(_Rule(_Verb.deny, _Kind.subpath, p));
      // lstat of each path component (realpath) must keep working —
      // DATA reads stay denied (E2: metadata-only under deny roots).
      reads.add(_Rule(_Verb.allow, _Kind.subpath, p, metadata: true));
    }
  }
  final reallow = <String>[
    ...kReadSystemReallows,
    runtime.projDir,
    runtime.agentRoot,
    runtime.tmp,
    ...runtime.runtimeDirs,
    ...runtime.extraRead,
    ...runtime.extraWrite, // rw grants read too
  ];
  final seenRead = <String>{};
  for (final root in reallow) {
    for (final p in bothSpellingsOf(root)) {
      if (seenRead.add(p)) {
        reads.add(_Rule(_Verb.allow, _Kind.subpath, p));
      }
    }
  }

  writes.sort(_compare);
  reads.sort(_compare);
  for (final r in writes) {
    lines.add(_emit(r, 'file-write*'));
  }
  for (final r in reads) {
    lines.add(_emit(r, 'file-read*'));
  }

  final text = '${lines.join('\n')}\n';
  final key10 = md5
      .convert(convert.utf8.encode(text))
      .toString()
      .substring(0, 10);
  return SbplProfile(text: text, key10: key10);
}
