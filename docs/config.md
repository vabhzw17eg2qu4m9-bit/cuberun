# Configuration reference

Everything `cube-sandbox` knows is in one place: a **harness manifest** — a
strict YAML document naming one AI harness launch and the folder grants
of its Layer-0 kernel profile. The same parser reads built-in presets,
project files, user files and scaffolds; there is no second, looser
dialect to drift out of sync.

Source of truth: `lib/src/harness_manifest.dart` (schema), `lib/src/paths.dart`
(path sanitation), `lib/src/resolver.dart` (precedence), `lib/src/runtime.dart`
(grant resolution), `lib/src/service_grants.dart` (`--use-*` catalog).

## File locations & resolution precedence

Given `cube-sandbox <verb> <name>`, the profile resolves through a fixed
precedence chain — first hit wins:

1. `--yaml '<text>'` / `--yaml -` (inline text, or stdin read to EOF) — highest
2. `--file <path>`
3. `<cwd>/.cube-sandbox/<name>.yaml` (project)
4. `~/.cube-sandbox/<name>.yaml` (user)
5. built-in preset: `fa` (`~/.fah`), `omp` (`~/.omp`), `pi` (`~/.pi`, widened)

Notes:

- For file sources the **filename stem is the profile id**:
  `.cube-sandbox/acme.yaml` is `cube-sandbox launch acme` even if its
  `metadata.name` says something else — what `cube-sandbox list` shows is
  what launches. `--yaml` has no filename: the profile name keys on
  `metadata.name`. The positional `<name>` is still typed for all
  sources (it names the profile in banners and diagnostics).
- `--yaml` and `--file` are mutually exclusive — giving both fails
  closed: `--yaml and --file: give one, not both` (exit 2), never
  silent precedence. `--yaml -` with empty stdin is likewise a config
  error, and parse errors on inline text name the source
  `<inline yaml>` (no filename exists to point at).
- A total miss fails loudly, listing every location searched and the
  preset ids:
  `profile 'x' not found — looked: --file (none), <cwd>/.cube-sandbox/x.yaml, ~/.cube-sandbox/x.yaml, presets(fa, omp, pi)`.
- `cube-sandbox list` enumerates presets + project + user files with source
  labels; a file that does not parse lists as
  `<parse error — run to see diagnostic>` and fails loudly when launched.
- Built-in presets are manifest TEXT parsed by the same strict parser —
  zero preset/user drift.

## Launch argv: options precede the profile

`cube-sandbox launch [options] <profile> [args…] [-- <command…>]` — the
positional split is the contract. Every cube-sandbox option (`--file`,
`--yaml`, `--use-*`, `--wait`) MUST precede the profile; **everything
after the profile is the harness's argv**, forwarded verbatim (order
preserved, no interpretation — `launch omp --resume <id>` resumes). A
`--file x` typed after the profile is the HARNESS's argument, not
cube-sandbox's. `-- <command…>` keeps its override role: it replaces
the harness command (the tail still appends after it). The boundary
never changes: the emitted SBPL profile is byte-identical with and
without a tail, and `--wait` exit codes propagate unchanged. `show` /
`sbpl` / `probe` / `new` / `list` stay strict: trailing options still
error.

### Spawn-and-exit (`--wait` to block)

`launch` is spawn-and-exit: resolve → preflight → stage → banner →
spawn `sandbox-exec -f <sb> <command…>` → **exit 0**. The launcher's
exit is the spawn status: `0` once the confined harness is running,
`126` fail-closed (nothing ran unconfined). The harness's own exit code
is neither observed nor waited on. Nothing after spawn depends on the
launcher: confinement is kernel-enforced on the harness process itself,
its inherited stdio fds stay open, the terminal's Ctrl-C reaches it
directly, and the orphaned process reparents to launchd. `--wait`
(before the profile) preserves the blocking contract verbatim:
cube-sandbox stays resident and forwards the harness exit code
(signal n ⇒ `128 + n`).

## Manifest schema

```yaml
apiVersion: cube-sandbox/v1        # required, exactly "cube-sandbox/v1"
kind: Harness                 # required, exactly "Harness"
metadata:                     # required map
  name: myagent               # required, ^[a-z][a-z0-9-]*$
  description: "…"            # optional string, shown by `cube-sandbox list`
spec:                         # required map
  command: myagent            # required — string OR argv list (below)
  agentRoot: ~/.myagent       # required state root (rw)
  agentRootEnv: MYAGENT_DIR   # optional env var overriding agentRoot
  widenToDotParent: true      # optional bool (default false)
  extraRead:                  # optional list of read-only grants
    - ~/.gitconfig
  extraWrite:                 # optional list of read-write grants
    - ~/.cache/myagent
  network: open               # optional; "open" is the only value in v1
```

### Every key, exactly

| key | type | required | rules |
| --- | --- | --- | --- |
| `apiVersion` | string | yes | exactly `cube-sandbox/v1` |
| `kind` | string | yes | exactly `Harness` |
| `metadata` | map | yes | only keys `name`, `description` |
| `metadata.name` | string | yes | must match `^[a-z][a-z0-9-]*$` |
| `metadata.description` | string | no | free text; `cube-sandbox list` shows it |
| `spec` | map | yes | only keys listed below |
| `spec.command` | string or list | yes | string → argv `[string]` (must be non-empty). List = argv, exec'd directly — **no shell**, no quoting/interpolation; each entry a non-empty string without NUL; list may not be empty. At launch, the command-line tail (args after the profile) appends AFTER this argv — a string command becomes `[string]` first |
| `spec.agentRoot` | path string | yes | non-empty; absolute or `~/`-prefixed (bare `~` ok); no `"`/newline/CR/NUL; **no `..` segments**; no trailing `/`. Stored lexically, `~` expands at resolve |
| `spec.agentRootEnv` | string | no | env var name `^[A-Za-z_][A-Za-z0-9_]*$`. When set **non-empty** at launch it overrides `agentRoot` (the value is tilde-expanded and sanitized the same way) |
| `spec.widenToDotParent` | bool | no | default `false`. Widens a dot-dir root one level: `~/.pi/agent` → `~/.pi` (skills/themes live next to agent state). Applied once, after any env override |
| `spec.extraRead` | list of paths | no | read-only grants; every entry sanitized like `agentRoot` |
| `spec.extraWrite` | list of paths | no | read-write grants; same sanitation |
| `spec.network` | string | no | only `open` in v1 (also the default when omitted). SBPL remote filters accept IP literals only while LLM endpoints sit on rotating CDN IPs; per-task network denies are the inner cubes' job, not Layer 0's |

**Strict parsing:** an unknown key at ANY level — top, `metadata`, or
`spec` — is an error naming the YAML path, with the sorted allow-list:

```
<path>.spec.extraread: unknown key (allowed: [agentRoot, agentRootEnv, command, extraRead, extraWrite, network, widenToDotParent])
```

Every schema violation (wrong `apiVersion`/`kind`, bad name, unknown
key, missing/empty command, relative or unsafe `agentRoot`,
non-list `extraRead`, `network: filtered`…) throws `ConfigException`
naming the YAML path: printed to stderr, exit 2. Nothing is silently
ignored — a typo can never degrade to "no grant" or "no confinement".

### Path sanitation (any declarative path)

`agentRoot`, `extraRead[]`, `extraWrite[]` all go through the same
sanitation. Rejected, with the YAML path in the message:

- empty / whitespace-only, or not a string
- not absolute and not `~/`-prefixed (relative paths: `must be absolute or ~/-prefixed`)
- contains `"` newline CR or NUL (`forbidden character`)
- any `..` segment (`".." climbs are not allowed`)
- trailing `/` (`trailing "/" not allowed`)

## What the resolved profile grants

The manifest is declarative; the profile is built from resolved machine
facts at launch:

- **rw** — the project dir (cwd) · the agent root (after env override +
  widening) · `realpath($TMPDIR)` (falls back to `/tmp`) · every
  `extraWrite` / service / env-knob write grant · `/dev/null` · `/dev/fd`.
- **ro** — system dirs (TLS trust store included) · **runtime dirs** of
  the launch command itself: each `PATH` dir, plus the parent prefix of
  a `<prefix>/bin` interpreter dir (module trees under `<prefix>/lib`
  stay readable) · every `extraRead` / service / env-knob read grant.
- **denied** — `/Users`, `/private/var`, `/Volumes`, `/Network`,
  `/home`, `/net` (both macOS spellings) outside the grants above;
  path *metadata* stays allowed so `realpath` works, *data* reads do
  not. All writes outside rw. **Network open** (deliberate, Layer 0).
- Grants merge **manifest → `--use-*` services → env knobs**, first
  occurrence wins (dedup).
- Deterministic: same (manifest, machine facts, `--use-*` set) ⇒
  byte-identical profile text and the same `key10` content id; any
  grant change ⇒ different `key10`.

## Service grants (`--use-*`)

Services GRANT FOLDERS; they never inspect, allow or forbid commands —
a confined `gh`, `glab` or `npm` simply cannot reach anything outside
the union of its grants. Flags append to the resolved profile before
the SBPL emit; multiple flags union and dedup, and flag order never
changes the output.

| flag | grants (shipped catalog — all read-only) | why |
| --- | --- | --- |
| `--use-github` | ro `~/.config/gh`, `~/.gitconfig` | gh token (hosts.yml, no Keychain) + git identity |
| `--use-gitlab` | ro `~/.config/glab`, `~/.gitconfig` | glab config; `~/.gitconfig` dedups with `--use-github` |
| `--use-nvm` | ro `~/.nvm` | any installed node under `~/.nvm/versions/node/<v>` works |

- Unknown service fails closed and loud, listing the catalog:
  `--use-x: unknown service (catalog: github, gitlab, nvm)` — never a
  silent ignore.
- Git under confinement: https public remotes work as-is; private
  https remotes need `--use-github`; ssh remotes deliberately fail —
  `~/.ssh` is ungrantable (below), so the failure is a loud auth error,
  never a silent grant.

## Env knobs

Colon-separated path lists, `~` expanded, empty entries dropped:

- `CUBE_SANDBOX_EXTRA_READ` — appended as read-only grants.
- `CUBE_SANDBOX_EXTRA_WRITE` — appended as read-write grants.

**Ungrantable roots (E10):** `~/.ssh`, `~/.gnupg`,
`~/Library/Keychains` (+ their `/private` spellings) — no manifest
path, service grant or `CUBE_SANDBOX_EXTRA_WRITE` may ever touch them:

- manifest/`agentRoot` violation → `ungrantable path(s) from manifest "name": …` (exit 2, launch refused)
- `CUBE_SANDBOX_EXTRA_WRITE` violation → hard error, launch refused (exit 2)
- `CUBE_SANDBOX_EXTRA_READ` violation → the single operator escape hatch:
  honored, but never silent — a loud `⚠ CUBE_SANDBOX_EXTRA_READ carries
  blocklisted path … operator override honored, NEVER silent (E10)`
  banner prints on every launch

## Scaffold & validation workflow

```sh
cube-sandbox new myagent --command myagent --agent-root ~/.myagent
# → .cube-sandbox/<name>.yaml, refuse-if-exists, round-trip parse-verified
#   (--command/--agent-root fail the same schema; name must match ^[a-z][a-z0-9-]*$)

cube-sandbox sbpl myagent               # exact kernel profile text — also THE parse check
cube-sandbox sbpl myagent --file p.yaml # validate a file without installing it
cube-sandbox show myagent               # resolved grants: rw / ro / denied banner
cube-sandbox probe myagent              # self-checks FROM INSIDE the profile; exit 0/1
cube-sandbox launch myagent                # launch (profile's own command) — spawn-and-exit
cube-sandbox launch --wait myagent         # block instead; forward the harness exit code
cube-sandbox launch myagent -- git status  # or any command under the same boundary
```

Exit codes: `0` ok — for `launch`, spawn success (the confined harness
is running and outlives the launcher) · `1` probe failure · `2` config
error (`ConfigException` diagnostics) · `64` usage · `126` fail-closed
(backend missing/rejecting — the command never runs unconfined) ·
under `launch --wait`, the harness's own code (signal n ⇒ `128 + n`).

## Examples

### 1. Minimal, pi-shaped (string command)

```yaml
# .cube-sandbox/pilike.yaml
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: pilike
  description: pi coding agent (state root ~/.pi)
spec:
  command: pi
  agentRoot: ~/.pi/agent
  agentRootEnv: PI_CODING_AGENT_DIR   # PI_CODING_AGENT_DIR=... overrides the root
  widenToDotParent: true              # ~/.pi/agent -> ~/.pi (skills live next to state)
  network: open
```

### 2. Custom harness with grants (argv command)

```yaml
# .cube-sandbox/myagent.yaml — launch: cube-sandbox launch --use-github myagent
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: myagent
  description: custom agent, node-based, with gh read access
spec:
  command:                # argv list — exec'd directly, no shell
    - node
    - /opt/tools/myagent/cli.js
    - --verbose
  agentRoot: ~/.myagent   # state root (rw)
  extraRead:              # read-only
    - ~/.gitconfig        # git identity (or just use --use-github)
  extraWrite:             # read-write
    - ~/.cache/myagent    # tool cache survives restarts
  network: open
```

### 3. One-shot wrapper (confine an arbitrary command)

```yaml
# .cube-sandbox/oneshot.yaml — launch: cube-sandbox launch oneshot -- claude -p "hi"
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: oneshot
  description: headless wrapper; the real command comes after --
spec:
  command: claude         # default when run without --
  agentRoot: ~/.claude
  extraRead:
    - ~/.npm              # npx-spawned MCP servers resolve
  network: open
```

Validate any of these before committing them:

```sh
cube-sandbox sbpl pilike --file .cube-sandbox/pilike.yaml   # parse + emit, no side effects
cube-sandbox probe pilike                              # boundary self-check
```
