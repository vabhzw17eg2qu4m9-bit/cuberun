# GOAL — cuberun (v3, adds --use service grants + tool-compat matrix)

## Goal — cuberun (v3, adds --use service grants + tool-compat matrix)

One sentence: **Every launch of a supported AI harness on this machine
(pi / omp / fa) becomes kernel-confined by default** — one compiled Dart
binary, `cuberun <harness>`, wraps the harness's entire process tree in a
Layer-0 `sandbox-exec` profile resolved from strict YAML, with three
built-in profiles and zero in-process gates to invent.

Today: two near-identical Node PoC launchers (`scripts/cube-pi.ts`,
`scripts/cube-omp.ts` in pi-vs-claude-code) confine pi and omp from the
terminal, configured only through per-script env knobs; fa has no Layer-0
story; every fix is copy-pasted between the two files and nothing is
installed system-wide. v1 turns the proven PoC semantics into one Dart
package that compiles to a binary (`dart compile exe`), installs globally,
and makes a new confined harness a YAML file instead of a fork.

## Why this framing

- **Retracted:** "confinement belongs inside the agent". Extensions load
  after the agent starts — the only seam that confines EVERYTHING the
  harness ever spawns (builtin bash, file tools, MCP servers) is the
  launcher. Live-verified by the PoC E2E.
- **Retracted:** "one hand-rolled script per harness". cube-pi.ts vs
  cube-omp.ts drift is the bug class this card kills: one engine, N
  profiles.
- **Retracted:** "add policy gates inside cuberun" (allowlists of
  commands, egress proxies). The owner's requirement is the OPPOSITE: no
  internal gates — restriction happens at the KERNEL sandbox level
  (reads of user data denied, writes denied outside grants), and
  finer-grained per-task denies belong to fa's inner L1+ cubes which
  already exist.
- NOT retracted: the two-layer model. Layer 0 (this launcher) stays
  permissive enough for a harness to live; L1+ cubes stay narrow.
- **Pinned principle (v2):** NO command denylists anywhere, ever — not
  for services, not for profiles. `--use-<service>` GRANTS FOLDERS, it
  never forbids commands: with the kernel folder restrictions in place,
  no command is dangerous — it simply cannot reach anything outside its
  grants (owner's exact reasoning, keep it verbatim in spirit).
- **Pinned principle (v3):** confinement must be INVISIBLE to working
  commands — every tool command that works unconfined (e.g. `git pull`)
  must work identically under the profile, or the profile is wrong, not
  the command. The tool-compat matrix (below) is the proof, per tool,
  per verb.

## Architecture

Named components (pure Dart except the two IO edges; style, gates and
verification conventions copied from flutter_agent_harness —
`analysis_options.yaml` with `lints/recommended`, doc comments on every
public member, `dart format` self-healing pre-commit, CI as the gate):

```
cuberun run pi
  │
  ├─ HarnessResolver ──► HarnessSpec        (strict YAML manifest)
  │    --file > <cwd>/.cuberun/<name>.yaml > ~/.cuberun/<name>.yaml > preset
  │
  ├─ HarnessPresets ────► pi | omp | fa     (manifest TEXT parsed by the
  │                                            same parser — no drift)
  ├─ ServiceGrants ─────► --use-github …    (folder grants appended to the
  │                                            resolved runtime: read-only
  │                                            configs, rw caches — unions,
  │                                            dedup, part of key10)
  ├─ HarnessRuntime ────► resolved facts    (cwd, agentRoot+env+widen,
  │                                            realpath($TMPDIR), env knobs,
  │                                            runtime dirs from PATH+shebang)
  ├─ SbplProfile ───────► deterministic SBPL (sorted rules, both spellings,
  │                                            md5-10 content key)
  ├─ ProfileStage ──────► .cuberun/cache/harness-<key10>.sb (atomic rename)
  ├─ Preflight ─────────► sandbox-exec probe (fail-closed ⇒ exit 126)
  └─ Launcher ──────────► sandbox-exec -f <sb> <command…> (exit passthrough)
```

Invariants:

- **Fail-closed:** missing/rejecting backend ⇒ the command does NOT run
  unconfined (exit 126 + diagnostic). Spawn errors likewise.
- **Deterministic:** same (manifest, machine facts) ⇒ byte-identical
  profile text ⇒ same `key10`; identical staged content is never
  rewritten (mtime-stable).
- **Writes deny-by-default** outside: project dir, agent root,
  `realpath($TMPDIR)`, EXTRA_WRITE grants, `/dev/null`, `/dev/fd`.
- **Reads of user data denied** — curated deny roots (`/Users`,
  `/private/var`, `/Volumes`, `/Network`, `/home`, `/net`, BOTH macOS
  spellings; metadata re-allowed so path resolution lives), grants
  re-allowed. System dirs stay readable (pinned fact E1).
- **Network open at Layer 0** (`(allow network*)`) — deliberate, see E1;
  per-task denies are the inner cubes' job.
- **No secrets in profiles:** manifests and staged `.sb` contain paths
  only; the child's env is inherited, never logged.
- **Signal faithfulness:** child killed by signal n ⇒ launcher exits
  `128 + n` (POSIX; the PoC's hard-coded 143 is generalized).
- **Grants, never gates (v2):** `--use-<service>` layers folder grants
  into the SAME deterministic pipeline (union + dedup, flag set included
  in `key10`); cuberun never inspects, allows or forbids commands — the
  kernel folder boundary is the only gate.

## Capability surface (everything the platform allows → our shape)

The SUBJECT of every capability is named; the platform is
macOS `sandbox-exec` (SBPL) + Dart `dart compile exe`.

| platform ability | our shape | notes |
| --- | --- | --- |
| confine a whole process tree | `cuberun run <profile> [-- cmd…]` | default command from the profile |
| enumerate profiles | `cuberun list` | presets + project + user, with source labels |
| inspect resolved grants | `cuberun show <profile>` | rw/ro/denied banner |
| inspect the exact kernel profile | `cuberun sbpl <profile>` | deterministic text, no secrets |
| create a profile | `cuberun new <name> --command … --agent-root …` | scaffolds `.cuberun/<name>.yaml`; must round-trip through the strict parser |
| verify the boundary | `cuberun probe <profile>` | self-checks FROM INSIDE the profile; exit 0/1 |
| relocate state dir | `agentRootEnv` per profile | `PI_CODING_AGENT_DIR`, `OMP_AGENT_DIR`; fa has none upstream yet |
| widen a dot-dir root | `widenToDotParent` | `~/.pi/agent` → `~/.pi` (skills/themes live next to state) |
| ad-hoc grants | `CUBERUN_EXTRA_READ` / `CUBERUN_EXTRA_WRITE` | colon-separated, `~` ok, appended to manifest grants |
| service folders grant | `cuberun run pi --use-github --use-gitlab` | unions the services' folder grants into the profile (see Service grants) |

### Profile manifests (subject: the YAML document)

`apiVersion: cuberun/v1`, `kind: Harness`, `metadata.name`
(`^[a-z][a-z0-9-]*$`), `spec`: `command` (string or argv list, required),
`agentRoot` (required, absolute or `~/`), `agentRootEnv`,
`widenToDotParent`, `extraRead[]`, `extraWrite[]`, `network` (`open`
only in v1). Strict parse: unknown key at ANY level ⇒ error naming the
YAML path — same discipline as flutter_agent_harness `.fah/cubes`.

### Built-in presets (subject: the three harnesses)

- **core (this card):** `pi`, `omp`, `fa` — the three launchers that
  exist on this machine today, each with its state root (`~/.pi`,
  `~/.omp`, `~/.fah`).
- **second tier (opt-in, follow-up):** any user harness via
  `cuberun new` + edits; Linux `unshare` backend; filtered network
  mode; profile `include`/composition.
- **excluded (with rationale):** Windows/job-object backend (no host);
  managing harness installs/updates (not a launcher's job); per-command
  allowlists inside cuberun (that is fa's cube layer — see Non-goals).

### Service grants (subject: each service's state folders)

`--use-<service>` appends that service's folder grants to the resolved
profile BEFORE the SBPL emit — read-only for configs/credentials the
service reads, rw only for its caches. Deterministic: the flag SET is
part of the content key. Composition: multiple `--use-*` flags union
and dedup. Unknown service is a LOUD `ConfigException` listing the
catalog — never a silent ignore (fail-closed). And by the pinned
principle above: services grant FOLDERS, they never touch commands —
a confined `gh`, `glab`, `npm` or anything else simply cannot reach
anything outside the union of grants.

- **core (this card):**
  - `--use-github` — ro: `~/.config/gh` (hosts.yml token, works without
    the Keychain), `~/.gitconfig` (identity + gh credential helper).
  - `--use-gitlab` — ro: `~/.config/glab`, `~/.gitconfig` (dedup with
    `--use-github`).
  - `--use-nvm` — ro: `~/.nvm` (node installs under
    `~/.nvm/versions/node/<v>/`, nvm.sh resolution state; synergie: the
    runtime-prefix detection already turns a PATH entry under `~/.nvm`
    into a read grant for the interpreter + its module tree — this flag
    makes the whole nvm root readable so ANY installed node works).
- **second tier (opt-in, follow-up):** `--use-npm` (ro `~/.npm`),
  `--use-pub` (rw `~/.pub-cache`), `--use-uv` (rw `~/.cache/uv`,
  `~/.local/share/uv`), `--use-cargo` (rw `~/.cargo`),
  `--use-pip` (ro `~/.config/pip`); user-defined service snippets
  `~/.cuberun/services/<name>.yaml` parsed through the same strict
  parser (resolution: project > user > built-in catalog).
- **excluded (with rationale):** `--use-ssh` and ANY grant touching
  `~/.ssh`, `~/.gnupg` or the login Keychain — never offered in the
  catalog and impossible-by-construction from user snippets (path
  blocklist, E10); `--use-docker` (the docker socket equals root on
  this host class).

### Tool compatibility (subject: each tool's FULL command set)

The owner's requirement, verbatim in spirit: for EVERY tool the
harnesses use, tests must run ALL of its commands inside the confined
profile to prove the sandbox config breaks NOTHING — `git pull` named
explicitly — and `pi`/`omp`/`fa` themselves must launch and work
without errors. Exhaustive verb inventory, tiered:

- **core — git (with `--use-github`):** status · log · diff · show ·
  branch · remote · add · commit · push · pull · fetch · clone ·
  checkout · switch · restore · stash · tag · merge · rebase ·
  rev-parse · config · ls-files · blame · describe · worktree ·
  cherry-pick · revert · clean · apply · rm · mv · rev-list ·
  ls-remote. Platform facts pinned: identity/credentials come from the
  granted `~/.gitconfig` + `~/.config/gh`; TLS for https remotes needs
  no carve-out at Layer 0 — system dirs (incl. `/etc/ssl` and its
  `/private/etc/ssl` spelling) stay readable by design (E1).
- **core — gh (with `--use-github`):** auth status · api · repo view ·
  issue/PR read+create · release view — token from `~/.config/gh`.
- **core — the harnesses themselves:** `pi`, `omp`, `fa` each must
  START under their Layer-0 profile and complete a trivial headless run
  answering OK (pi: `pi --no-session -p "Reply with OK"`; omp/fa:
  equivalent headless modes) — provider keys arrive via inherited env
  (never logged), egress rides the open Layer-0 network (E1).
- **second tier (opt-in, follow-up):** glab (with `--use-gitlab`),
  node/npm/npx (with `--use-npm`/`--use-nvm`), cargo, uv, pip — same
  full-verb treatment per tool as they gain flags.
- **excluded from testing (with rationale; NOTHING is forbidden to
  RUN):** `brew`, `sudo`, Keychain-touching `security` — not part of a
  confined harness workflow on this host class; and destructive git
  verbs against the HOST repos (`push --force` to origin main of a
  foreign repo) — the matrix runs them against disposable fixture
  remotes only.

### Distribution (subject: the binary)

- **core:** `dart compile exe` → single static binary; `just build`;
  install to `~/.local/bin` (documented; the agent's own dev cube denies
  that path — install is a human/CI action).
- **core:** GitHub repo (vabhzw17eg2qu4m9-bit/cuberun), Actions ONLY on the latest
  macOS arm64 runner (`macos-15`): `analyze` (format
  --set-exit-if-changed + `dart analyze --fatal-infos`), `test` (unit,
  `--exclude-tags integration`), `integration` (E2E, `--tags
  integration` — probe suite, git/gh tool-compat matrices against the
  workflow token, harness launch smoke when provider env exists),
  `build` (`dart compile exe` + smoke: `--version`,
  `list`, `sbpl fa`, `probe fa` + artifact upload `cuberun-macos-arm64`).
- **excluded:** ubuntu/linux CI legs (the backend is macOS-only; unit
  tests still run on macOS), cross-builds, Homebrew tap (second tier).

## Acceptance criteria (testable)

- **AC1** — strict parse: every schema violation (wrong apiVersion/kind,
  bad name, unknown key at any level, missing/empty command, relative
  or unsafe agentRoot, non-list extraRead…) throws `ConfigException`
  naming the YAML path (UT table).
- **AC2** — presets: exactly `fa`, `omp`, `pi` ship, each parses through
  the strict parser with its own agent root (UT).
- **AC3** — resolution precedence: `--file` > project `.cuberun/` >
  user `~/.cuberun/` > preset; not-found error lists where it looked
  and the preset ids (IT with temp dirs).
- **AC4** — determinism: identical runtime facts ⇒ byte-identical SBPL
  and `key10`; ANY grant change ⇒ different `key10`; rules emitted in
  comparator order (two sorted runs: writes then reads) (UT).
- **AC5** — fail-closed: preflight refuses non-macOS, missing binary,
  and rejecting backends — injected runner covers all three without a
  host (UT/IT).
- **AC6** — live boundary: on a macOS arm64 host the full probe passes
  (write-outside denied, project rw works, `$HOME` read+write+listing
  denied outside grants, EXTRA_READ read-only, EXTRA_WRITE rw, network
  open) AND a sabotaged profile makes the probe FAIL (negative control)
  (E2E, `integration` tag).
- **AC7** — exit faithfulness: signal n ⇒ `128+n`, codes pass through
  (UT on the mapping + E2E smoke).
- **AC8** — scaffold round-trip: `cuberun new` output parses through
  the strict parser and lands in `.cuberun/<name>.yaml` (IT).
- **AC9** — gates green: `dart format --set-exit-if-changed`,
  `dart analyze --fatal-infos`, `dart test --exclude-tags integration`
  all pass on the macOS arm64 CI runner.
- **AC10** — service grants: `--use-github` adds EXACTLY the cataloged
  grants (read-allows for `~/.config/gh` + `~/.gitconfig`, no
  write-allows) and changes `key10`; `--use-gitlab` ∪ `--use-github`
  dedups `~/.gitconfig`; an unknown `--use-x` is a loud
  `ConfigException` listing the catalog (UT). E2E: with `--use-github`
  the gh config is READABLE, still NOT writable, the rest of `$HOME`
  stays denied (probe variant green).
- **AC11** — grant safety: no `--use-*` path (built-in or user snippet)
  can ever emit an allow touching `~/.ssh`, `~/.gnupg` or keychain
  files — rejected at resolve, asserted by a REG byte-scan of all
  emitted profiles (E10).
- **AC12** — tool-compat matrix, git: EVERY verb in the core git
  inventory (incl. `pull`, `push`, `clone` over https) runs inside the
  `pi`/`fa` profile with `--use-github` against disposable fixture
  remotes and the real github.com (CI: workflow token) with IDENTICAL
  outcomes to the unconfined baseline — zero sandbox-induced failures
  (E2E `integration`).
- **AC13** — harness launch: `pi`, `omp` and `fa` each start under
  their own Layer-0 profile and complete a trivial headless run
  answering OK, with stderr free of sandbox denials (E2E `integration`;
  requires provider env — skipped with reason when absent, NEVER
  silently passed).
- **AC14** — tool-compat regression pin: the per-tool verb matrix is
  data (a pinned catalog); adding a git subcommand to the suite without
  extending the catalog fails the REG guard, and any matrix failure
  blocks merge exactly like `integration`.

## Test plan

### Test matrix — maximal coverage, zero cross-platform breakage

- `UT-*` pure, no IO: strict-parse table (AC1), presets (AC2), SBPL
  emit/determinism/order/both-spellings (AC4, E1, E2), exit mapping
  (AC7), path sanitation (E4), service-grant catalog — exact folders,
  union/dedup, unknown-service failure, key10 sensitivity (AC10).
- `IT-*` real temp dirs: resolver precedence + loud failures (AC3),
  content-addressed staging / no-rewrite (AC8, E7), scaffold round-trip.
- `E2E-*` real host, macOS arm64 only, tagged `integration` (skipped
  with reason elsewhere): preflight injections (AC5), full probe +
  negative control (AC6), `--use-github` read-only grant variant
  (AC10), binary smoke (`--version`, `list`, `sbpl`, `probe`) in CI's
  build job.
- `TOOL-*` (a flavor of E2E, same tag): per-tool full-verb matrices —
  git (all ~31 verbs, fixture remotes + real github.com in CI, AC12),
  gh (AC12), harness launch smoke for pi/omp/fa (AC13). Each verb
  asserts confined-vs-unconfined outcome equality; the verb lists are
  data from the pinned catalog (AC14).
- `REG-*` regression guards: SBPL text of all three presets asserted
  against pinned expectations (deny roots, metadata re-allows, grant
  lines) — a diff in preset confinement is a RED build even when all
  behavior tests stay green; staged `.sb` byte-scan proves NO secret
  patterns (env values, tokens) ever enter the profile; the
  service-grant CATALOG is pinned — a folder list change without a GOAL
  revision is a red build; no profile for ANY flag combination
  contains an allow for ssh/gnupg/keychain paths (AC11, E10); the
  tool-verb catalog is pinned (AC14).

CI wiring (GitHub Actions, `macos-15` arm64 only, single `ci.yml`):
jobs `analyze` / `test` / `integration` / `build` as in Distribution.
Merge rule: **a red `integration` or `build` job blocks merge even when
`test` is green**; `test` never substitutes for `integration`.

### Edge / border cases

- **E1 — blanket read-deny is unbuildable.** A bare `(deny file-read*)`
  makes the SBPL compiler ABORT (`Abort trap: 6`, live-verified in the
  PoC on every such profile regardless of allows). Consequence: reads
  use curated denies over user-data roots; system dirs stay readable.
  Also the reason Layer-0 network is `(allow network*)`: SBPL remote
  filters accept IP literals only (no hostnames, live-verified) while
  LLM endpoints sit on rotating CDN IPs. Pinned: REG asserts the
  curated root list; E2E asserts `$HOME` reads denied.
- **E2 — dual spellings.** `/var ⇄ /private/var` (and `/Users ⇄
  /private/Users`) must BOTH be denied or the kernel spelling escapes
  the rule; `$TMPDIR` must be realpath'd to its `/private` spelling.
  UT asserts both spellings in the text.
- **E3 — sandbox-exec deprecation warning** on newer macOS: stderr
  passes through; the probe still must pass (E2E tolerates the warning).
- **E4 — SBPL literal injection.** Manifest/env paths containing `"`,
  newline, or `..` climbs are REJECTED at parse/resolve
  (impossible-by-construction); UT feeds attack strings.
- **E5 — PATH lookup happens INSIDE the sandbox.** The dir holding the
  command (and its shebang interpreter, e.g. node for pi) must be
  read-granted or nothing starts; runtime-prefix detection covers
  `<prefix>/lib` module trees. UT on prefix logic; E2E smoke.
- **E6 — signals.** Ctrl-C reaching the child (SIGINT) must surface as
  130, not cuberun's own exit; UT on the mapping.
- **E7 — stale staged profiles.** Content-keyed filenames make
  collisions impossible; identical text is not rewritten (mtime
  stable); old keys accumulate harmlessly under the gitignored cache.
- **E8 — profile file with mismatched `metadata.name`** vs filename:
  resolution keys on the FILENAME stem; listings display under the same
  stem so what lists is what launches.
- **E9 — service-grant composition.** Repeated flags, `--use-github` ∪
  `--use-gitlab`, and env-knob appends must union and DEDUP (duplicate
  subpath rules are harmless to the kernel but break determinism
  guarantees); flag order must never change the emitted text (UT).
  An unknown `--use-<x>` fails closed with the catalog listed — a typo
  must never degrade to "no grant".
- **E10 — ungrantable paths.** `~/.ssh`, `~/.gnupg`, `~/Library/
  Keychains` (and their `/private` spellings) are rejected at resolve
  from every DECLARATIVE source — built-in catalog, user service
  snippets, manifest `extraRead`/`extraWrite` —
  impossible-by-construction; REG byte-scans every emitted profile for
  those allow lines. The single escape hatch is the human-typed
  `CUBERUN_EXTRA_READ` env knob (operator's explicit decision): it is
  honored but NEVER silent — `run`/`show` print a loud ⚠ banner naming
  the blocklisted path it carries.
- **E11 — `git pull` / network remotes under confinement.** https
  remotes need no TLS carve-out at Layer 0 (system dirs readable, E1),
  but credentials do: without `--use-github` a pull from a private
  remote fails auth — that is the DESIRED behavior, and the matrix
  asserts the failure MODE (auth, not sandbox denial). ssh remotes
  deliberately fail (E10) — documented, loud, expected.
- **E12 — tool-matrix drift.** New tool versions grow verbs (git gains
  subcommands); the matrix is data, pinned by REG (AC14) — a suite
  extension without a catalog update is red, and a catalog update
  without a GOAL revision is red. Fixture remotes are disposable
  (created per run, never the host's real repos).

## Non-goals

- No in-process policy gates (command allowlists, egress proxies) —
  kernel confinement only; per-task narrowing is fa's cube layer.
- No Linux/Windows backends in v1.
- No network filtering at Layer 0 (E1 platform fact).
- No harness lifecycle management (install/update pi/omp/fa).
- No new chat/UI anything — cuberun wraps, it never runs interactively.

## Open questions

- fa exposes no env var for its home today; the fa preset ships without
  `agentRootEnv` until upstream grows one — override via a user profile
  file meanwhile. (Owner call: none needed for v1.)
- Repo visibility: created private under the authenticated account
  (`vabhzw17eg2qu4m9-bit/cuberun`, token scopes `repo`+`workflow`);
  flip to public when the owner decides.

## References

- `scripts/cube-pi.ts`, `scripts/cube-omp.ts`, `scripts/cube-selftest.ts`
  — the PoC this card promotes (pi-vs-claude-code).
- `extensions/cube-core.ts` — SBPL engine semantics (bothSpellings,
  normalizeLexicalPath, rule ordering).
- flutter_agent_harness `lib/src/cube/**` — strict-manifest style,
  resolver precedence, preset-through-parser pattern;
  `scripts/pre-commit` / `ci_fast_gate.sh` — gate style.
- omp-cube GOAL — E1/E3 experiment log (blanket deny abort;
  deprecation warning).
