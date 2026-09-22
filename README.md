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
cube-sandbox launch pi                     # launch pi confined — spawn-and-exit
cube-sandbox launch --wait pi              # ... or block and forward the exit code
cube-sandbox launch --use-github pi        # + gh config/git identity (read-only)
cube-sandbox launch omp --resume <id>      # args after the profile go to the harness
cube-sandbox launch fa -- git status       # confine an arbitrary command
cube-sandbox list                       # presets + project + user profiles
cube-sandbox show pi                    # rw/ro/denied banner
cube-sandbox sbpl pi                    # exact deterministic profile text
cube-sandbox new myh --command myh --agent-root ~/.myh
cube-sandbox probe pi                   # self-checks FROM INSIDE the profile
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
- **Spawn-and-exit** — `launch` exits 0 once the confined harness is
  running (the exit code is the spawn status, not the harness's). The
  kernel enforces the boundary on the harness process itself: its fds,
  the terminal's Ctrl-C and launchd reparenting all work without a
  resident parent. `--wait` opts back into blocking + exit forwarding.
- **Signal faithfulness** — under `--wait`, a child killed by signal n
  makes the launcher exit `128 + n`.
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

## Exit codes

`0` ok — for `launch`, spawn success: the confined harness is running
and outlives cube-sandbox (spawn-and-exit) · `1` probe failure · `2`
config error · `64` usage · `126` fail-closed (backend
missing/rejecting) · under `launch --wait`, the harness's own code
(signal n ⇒ 128+n).

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
