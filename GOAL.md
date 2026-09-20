# GOAL — cuberun (v1, initial card)

## Goal — cuberun (v1, first draft)

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

### Distribution (subject: the binary)

- **core:** `dart compile exe` → single static binary; `just build`;
  install to `~/.local/bin` (documented; the agent's own dev cube denies
  that path — install is a human/CI action).
- **core:** GitHub repo (vabhzw17eg2qu4m9-bit/cuberun), Actions ONLY on the latest
  macOS arm64 runner (`macos-15`): `analyze` (format
  --set-exit-if-changed + `dart analyze --fatal-infos`), `test` (unit,
  `--exclude-tags integration`), `integration` (E2E, `--tags
  integration`), `build` (`dart compile exe` + smoke: `--version`,
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

## Test plan

### Test matrix — maximal coverage, zero cross-platform breakage

- `UT-*` pure, no IO: strict-parse table (AC1), presets (AC2), SBPL
  emit/determinism/order/both-spellings (AC4, E1, E2), exit mapping
  (AC7), path sanitation (E4).
- `IT-*` real temp dirs: resolver precedence + loud failures (AC3),
  content-addressed staging / no-rewrite (AC8, E7), scaffold round-trip.
- `E2E-*` real host, macOS arm64 only, tagged `integration` (skipped
  with reason elsewhere): preflight injections (AC5), full probe +
  negative control (AC6), binary smoke (`--version`, `list`, `sbpl`,
  `probe`) in CI's build job.
- `REG-*` regression guards: SBPL text of all three presets asserted
  against pinned expectations (deny roots, metadata re-allows, grant
  lines) — a diff in preset confinement is a RED build even when all
  behavior tests stay green; staged `.sb` byte-scan proves NO secret
  patterns (env values, tokens) ever enter the profile.

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
