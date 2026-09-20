# cuberun

[![CI](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/actions/workflows/ci.yml/badge.svg)](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/actions/workflows/ci.yml)
[![release](https://img.shields.io/github/v/release/vabhzw17eg2qu4m9-bit/cuberun)](https://github.com/vabhzw17eg2qu4m9-bit/cuberun/releases/latest)
![tests](.badges/tests.svg)
![coverage](.badges/coverage.svg)
![crap4dart](.badges/crap4dart.svg)

**Every launch of a supported AI harness on this machine (pi / omp / fa)
becomes kernel-confined by default.**

One compiled Dart binary, `cuberun <harness>`, wraps the harness's entire
process tree in a Layer-0 `sandbox-exec` profile resolved from a strict
yaml manifest — builtin tools, spawned shells, MCP servers, everything
the harness ever does is born inside the kernel boundary. Extensions
cannot do this (they load after the agent starts); the launcher is the
only seam that confines everything.

```
cuberun run pi                     # launch pi confined
cuberun run pi --use-github        # + gh config/git identity (read-only)
cuberun run fa -- git status       # confine an arbitrary command
cuberun list                       # presets + project + user profiles
cuberun show pi                    # rw/ro/denied banner
cuberun sbpl pi                    # exact deterministic profile text
cuberun new myh --command myh --agent-root ~/.myh
cuberun probe pi                   # self-checks FROM INSIDE the profile
```

## Confinement model (Layer 0)

- **Writes deny-by-default** — allowed only for: the project dir, the
  harness state root, `realpath($TMPDIR)`, `CUBERUN_EXTRA_WRITE` grants,
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
- **Signal faithfulness** — child killed by signal n ⇒ exit `128 + n`.
- **Grants, never gates** — cuberun never inspects, allows or forbids
  commands; the kernel folder boundary is the only gate.

## Profiles

```yaml
apiVersion: cuberun/v1
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
Resolution: `--file` > `<cwd>/.cuberun/<name>.yaml` > `~/.cuberun/` >
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
`CUBERUN_EXTRA_READ` env knob: honored, never silent (loud ⚠ banner).

**Git remotes under confinement**: **https** remotes work for public
repos as-is; **private** https remotes need `--use-github` so the gh
token and `~/.gitconfig` are readable — without it a private clone fails
with the remote's auth error (the desired failure mode, E11). **ssh**
remotes deliberately fail: `~/.ssh` is ungrantable (E10 — key material
stays out of every profile by construction), so a confined
`git@github.com:…` remote is a loud auth failure, never a silent grant.

## Env knobs

- `CUBERUN_EXTRA_READ` — colon-separated read-only grants (`~` ok)
- `CUBERUN_EXTRA_WRITE` — colon-separated read-write grants; blocklisted
  paths are rejected outright

## Exit codes

`0` ok · `1` probe failure · `2` config error · `64` usage · `126`
fail-closed (backend missing/rejecting) · otherwise the child's code
(signal n ⇒ 128+n).

## Docs & agent skill

- Full manifest reference (schema, precedence, grants, E10): [docs/config.md](docs/config.md)
- Agent skill — author, validate, launch and probe profiles: [skills/cuberun-config/SKILL.md](skills/cuberun-config/SKILL.md)
- Install: `cp -r skills/cuberun-config ~/.pi/agent/skills/` (same for `~/.omp/agent/skills/`)

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

Installing (human/CI action; the agent's own dev cube denies
`~/.local/bin`): `just build && cp build/cuberun-macos-arm64 ~/.local/bin/cuberun`.
