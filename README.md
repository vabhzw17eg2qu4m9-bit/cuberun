# cube-sandbox

[![CI](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/actions/workflows/ci.yml/badge.svg)](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/vabhzw17eg2qu4m9-bit/cuberun)](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/releases/latest)
![tests](.badges/tests.svg)
![coverage](.badges/coverage.svg)
![crap4dart](.badges/crap4dart.svg)

**Every launch of a supported AI harness on this machine (pi / omp / fa)
becomes kernel-confined by default.**

One compiled Dart binary, `cube-sandbox <harness>`, wraps the harness's entire
process tree in a Layer-0 `sandbox-exec` profile resolved from a strict
yaml manifest — builtin tools, spawned shells, MCP servers, everything
the harness ever does is born inside the kernel boundary. Extensions
cannot do this (they load after the agent starts); the launcher is the
only seam that confines everything.

```
cube-sandbox launch pi                     # launch pi confined — from a terminal, holds
                                           # the foreground for pi; headless: spawn-and-exit
cube-sandbox launch --wait pi              # always block + forward the exit code
cube-sandbox launch --spawn-exit pi        # always spawn-and-exit, even from a terminal
cube-sandbox launch --use-github pi        # + gh config/git identity (read-only)
cube-sandbox launch omp --resume <id>      # args after the profile go to the harness
cube-sandbox launch fa -- git status       # confine an arbitrary command
cube-sandbox list                       # presets + project + user profiles
cube-sandbox show pi                    # rw/ro/denied banner
cube-sandbox sbpl pi                    # exact deterministic profile text
cube-sandbox new myh --command myh --agent-root ~/.myh
cube-sandbox probe pi                   # self-checks FROM INSIDE the profile
cube-sandbox clean                      # wipe <cwd>/.cube-sandbox/cache (run between sessions)
```

## Confinement model (Layer 0)

- **Writes deny-by-default** — allowed only for: the project dir, the
  harness state root, `realpath($TMPDIR)`, `CUBE_SANDBOX_EXTRA_WRITE` grants,
  `/dev/null`, `/dev/fd`.
- **Reads of user data denied** — curated deny roots (`/Users`,
  `/private/var`, `/Volumes`, `/Network`, `/home`, `/net`, BOTH macOS
  spellings) with metadata re-allows so path resolution lives; system
  dirs stay readable (a blanket `(deny file-read*)` makes the SBPL
  compiler abort — that is a platform fact, not a choice).
- **Network open at Layer 0** — deliberate: SBPL remote filters accept
  IP literals only while LLM endpoints sit on rotating CDN IPs.
  Per-task denies are the inner cubes' job (two-layer model).
- **Fail-closed** — missing/rejecting backend means the command does NOT
  run unconfined: exit 126 + diagnostic.
- **Spawn-and-exit (headless) / foreground-hold (tty)** — for headless
  callers, `launch` exits 0 once the confined harness is running (the
  exit code is the spawn status, not the harness's). For a caller with
  a terminal on stdin, the launcher instead **holds the foreground for
  the harness's lifetime** (issue #81): exiting first would hand the
  tty back to the shell's job control, leaving the harness's process
  group orphaned in the background — where raw-mode `tcsetattr` dies
  with EIO and TUIs crash at startup. `--wait` forces the blocking
  shape everywhere; `--spawn-exit` forces the legacy spawn-and-exit
  from a terminal. **Automation note (vs v0.3.1):** callers attached
  to a pty (docker -t, tmux panes, CI with a tty) now get the blocking
  shape by default — pass `--spawn-exit` to keep spawn-and-exit.
- **Terminal inheritance on every launch path** — the spawn is
  byte-identical whether the profile was freshly staged, cache-hit, or
  rebuilt after an edit: caller's stdio, no detach, no new session, no
  re-parenting. The profile itself never names tty devices and never
  denies raw-mode ioctls — `(allow default)` covers them, and the
  byte-level audit tests pin that. Equivalence is asserted by tests
  (`CUBE_SANDBOX_SPAWN_LOG` records each spawn) and the manual repro
  below, not assumed from source shape.
- **Signal faithfulness** — under `--wait` (and any tty launch), a
  child killed by signal n makes the launcher exit `128 + n`; a Ctrl-C
  on a real terminal reaches the harness, and the launcher ignores its
  own copy of the SIGINT so the harness's death — not cube-sandbox's —
  is what surfaces. The hold also covers headless `--wait`: an explicit
  SIGINT to the launcher pid itself is ignored until the harness exits
  (deliberate E6 tradeoff); the harness still receives its own signals
  untouched.
- **Grants, never gates** — cube-sandbox never inspects, allows or forbids
  commands; the kernel folder boundary is the only gate.

## Profiles

```yaml
apiVersion: cube-sandbox/v1
kind: Harness
metadata:
  name: pi
spec:
  command: pi              # string or argv list
  agentRoot: ~/.pi/agent   # state root (rw)
  agentRootEnv: PI_CODING_AGENT_DIR
  widenToDotParent: true   # ~/.pi/agent -> ~/.pi
  extraRead: []            # read-only grants
  extraWrite: []           # read-write grants
  network: open            # v1: open only
```

Strict parse: any unknown key at any level fails naming the YAML path.
Resolution: `--file` > `<cwd>/.cube-sandbox/<name>.yaml` > `~/.cube-sandbox/` >
preset. Built-in presets: `fa` (`~/.fah`), `omp` (`~/.omp`),
`pi` (`~/.pi`, widened) — parsed by the same parser as user files.

## Profile cache (rebuild, provenance, clean)

Every launch re-resolves the manifest and re-emits the profile; staged
files are content-addressed (`key10` = first 10 hex of md5 of the profile
text), so **any change to the resolved configuration ⇒ a different key10 ⇒
the next launch runs the current configuration** — a stale `.sb` can never
be picked when the source that produced it changed.

**What the key sees (rebuilds) vs never sees (no rebuild):** key10 is a
pure function of the emitted profile — the manifest spec fields, the
`--use-*` service flags, the `CUBE_SANDBOX_EXTRA_READ` / `_WRITE` env
knobs, and `realpath($TMPDIR)`. Per-launch volatile argv — `--session`
uuids, `-e` extension args, anything after the profile name — rides the
harness's argv verbatim and **never changes the key**: identical config +
different session id ⇒ same `key10`, no rewrite, no warning.

Each staged `harness-<key10>.sb` keeps a `.src` provenance stamp beside it (a
fingerprint of the resolved source document); if the same key is ever
re-staged from a changed source, launch says so loudly:

```
⚠  cache provenance refreshed for harness-<key10>.sb (was staged from: …)
```

If the same profile stem exists in more than one resolution location
(project `.cube-sandbox/` and user `~/.cube-sandbox/`) with **differing**
content, `launch`/`show`/`sbpl` print a shadow warning naming the losing
copy — the banner `source :` line always names the file that actually
launches. Identical copies are not noise.

`cube-sandbox clean` deletes `<cwd>/.cube-sandbox/cache/` (every staged
profile + stamp). **Run it between sessions**: different `--use-*` sets
legitimately keep several keys live at once, so there is deliberately no
launch-time GC — the next launch simply re-stages what it needs. An
unreadable or corrupt cache file is rebuilt in place (atomic rename),
never crashes the launch and never lets the harness run unconfined
(fail-closed 126 is the floor).

## Service grants (`--use-*`)

Services GRANT FOLDERS; they never forbid commands — a confined `gh` or
`glab` simply cannot reach anything outside the union of grants.

- `--use-github` — ro `~/.config/gh`, `~/.gitconfig`
- `--use-gitlab` — ro `~/.config/glab`, `~/.gitconfig` (dedups)
- `--use-nvm` — ro `~/.nvm` (any installed node works)

Unknown `--use-x` fails closed listing the catalog. **Never grantable**:
`~/.ssh`, `~/.gnupg`, `~/Library/Keychains` — rejected from every
declarative source (impossible-by-construction, asserted by REG
byte-scans). The single operator escape hatch is the human-typed
`CUBE_SANDBOX_EXTRA_READ` env knob: honored, never silent (loud ⚠ banner).

**Git remotes under confinement**: **https** remotes work for public
repos as-is; **private** https remotes need `--use-github` so the gh
token and `~/.gitconfig` are readable — without it a private clone fails
with the remote's auth error (the desired failure mode, E11). **ssh**
remotes deliberately fail: `~/.ssh` is ungrantable (E10 — key material
stays out of every profile by construction), so a confined
`git@github.com:…` remote is a loud auth failure, never a silent grant.

## Env knobs

- `CUBE_SANDBOX_EXTRA_READ` — colon-separated read-only grants (`~` ok)
- `CUBE_SANDBOX_EXTRA_WRITE` — colon-separated read-write grants; blocklisted
  paths are rejected outright
- `CUBE_SANDBOX_SPAWN_LOG` — path; each `launch` appends one JSON line
  describing the spawn (`backend` / `argv` / `mode` / `wait`). Diagnostics
  for terminal-control issues: every launch path must produce an identical
  record for identical arguments. A broken path never fails a launch.

## Interactive TUIs & terminal control (issue #81)

TUI harnesses need raw-mode terminal input (`tcsetattr` on the tty). The
launcher's contract, enforced on **every** launch path (fresh build,
cache hit, rebuild-after-edit; spawn-and-exit and `--wait`):

1. **Inherited stdio** — the harness gets the caller's stdin/stdout/stderr
   (`ProcessStartMode.inheritStdio`, no detach, no new session, no
   re-parenting). Asserted by IT tests via `CUBE_SANDBOX_SPAWN_LOG`.
2. **Foreground continuity** — from a terminal, cube-sandbox stays the
   foreground job for the harness's lifetime, so the shell's job control
   never hands the tty away from under the harness. Headless callers keep
   spawn-and-exit (#53): the parent leaves immediately, the kernel keeps
   the boundary.
3. **No tty rules in the profile** — the emitted SBPL never names
   `/dev/tty*`, never denies ioctls; raw mode needs **zero** grants, and
   grant-widening for terminal trouble would only weaken confinement.

**Manual repro / verification (needs a real terminal — CI has no tty):**
in a terminal, run the reporter's scenario in all three states and confirm
the TUI (or `stty raw -echo`) works each time:

```
cube-sandbox clean                                                  # state 1: cold cache
CUBE_SANDBOX_SPAWN_LOG=/tmp/spawn.jsonl cube-sandbox launch <profile> \
  -e extensions/pi-pi.ts --session 01a0be35-369a-76ea-9cde-c4b2d48cc79c
CUBE_SANDBOX_SPAWN_LOG=/tmp/spawn.jsonl cube-sandbox launch <profile> \
  -e extensions/pi-pi.ts --session 01a0be35-369a-76ea-9cde-c4b2d48cc79c
                                                                    # state 2: cache-hit, IDENTICAL args
cube-sandbox launch <profile> --session <different-uuid>            # C2: same profile key, no warning
# edit the manifest (e.g. widen extraWrite), then relaunch          # state 3: rebuild
cat /tmp/spawn.jsonl                                                # states 1+2: byte-identical records
```

Expected: the harness reaches its TUI with no `setRawMode EIO`; state 2
shows the same `profile <key10>` as state 1 and no warnings; state 3
rebundles under a new key only if a pinned emit input changed; the spawn
log records byte-identical spawns for identical arguments. If raw mode
still fails, capture the spawn log plus `ps -o pid,ppid,pgid,tpgid,stat,tt
-p <harness-pid>` — a background/orphaned state (`tpgid != pgid`) points
at the outer environment (SSH without pty, nested sandbox, wrapper), not
at the profile.

## Exit codes

`0` ok — for `launch` headless, spawn success: the confined harness is
running and outlives cube-sandbox (spawn-and-exit) · from a terminal or
under `launch --wait`, the harness's own code (signal n ⇒ 128+n) · `1`
probe failure · `2` config error · `64` usage · `126` fail-closed
(backend missing/rejecting).

## Docs & agent skill

- Full manifest reference (schema, precedence, grants, E10): [docs/config.md](docs/config.md)
- Agent skill — author, validate, launch and probe profiles: [skills/cube-sandbox-config/SKILL.md](skills/cube-sandbox-config/SKILL.md)
- Install: `cp -r skills/cube-sandbox-config ~/.pi/agent/skills/` (same for `~/.omp/agent/skills/`)

## Development

```sh
just test          # UT + IT + REG (no kernel sandbox needed)
just integration   # E2E: probe battery, git/gh matrices, harness suites
just build         # single static binary
```

CI (`.github/workflows/ci.yml`, macos-15 arm64): `analyze` / `test` /
`integration` / `build` — a red `integration` or `build` blocks merge
even when `test` is green. Harness suites skip with an explicit reason
when provider env is absent — skipped and failed are different colors.

## Install

macOS (Apple Silicon), one line:

```sh
curl -fsSL https://github.com/vabhzw17eg2qu4m9-bit/cuberun/releases/latest/download/install.sh | sh
```

Pinned version (`0.2.0` form also accepted):

```sh
curl -fsSL https://github.com/vabhzw17eg2qu4m9-bit/cuberun/releases/latest/download/install.sh | sh -s -- v0.2.0
```

| Env | Default | Purpose |
| --- | --- | --- |
| `CUBE_SANDBOX_INSTALL_DIR` | `~/.cube-sandbox` | install root (binary at `bin/cube-sandbox`) |
| `CUBE_SANDBOX_VERSION` | latest release | version to install |
| `CUBE_SANDBOX_GITHUB_TOKEN` | unset | optional auth (rate limits / private forks) |
| `CUBE_SANDBOX_DOWNLOAD_BASE` | GitHub Releases | artifact root override (mirrors / tests) |

From source: `just build && cp build/cube-sandbox-macos-arm64 ~/.local/bin/cube-sandbox`
(human/CI action; the agent's own dev cube denies `~/.local/bin`).
