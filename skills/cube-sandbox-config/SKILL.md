---
name: cube-sandbox-config
description: >
  Configure, author and validate cube-sandbox harness profiles — the strict
  YAML manifests (.cube-sandbox/<name>.yaml, ~/.cube-sandbox/<name>.yaml) that
  define kernel-confined launches of AI harnesses. Covers locating or
  creating a profile, validating it with cube-sandbox sbpl/show, launching
  with cube-sandbox launch, probing the boundary with cube-sandbox probe, adding
  --use-* service grants, and the E10 blocklist (~/.ssh, ~/.gnupg,
  ~/Library/Keychains are ungrantable). Use when asked to sandbox a
  harness, add/change a cube-sandbox profile or its grants, or debug a
  profile that fails to parse or launch.
when_to_use: Creating, editing, validating or launching cube-sandbox profiles
  (.cube-sandbox/*.yaml) — scaffolding a new confined harness, adding folder
  grants or --use-* services, checking why a manifest is rejected, or
  verifying the sandbox boundary — never for running an already-good
  profile (just `cube-sandbox launch <name>`).
argument-hint: "[profile name or task, e.g. 'confine myagent with rw ~/.cache/myagent']"
allowed-tools:
  - read
  - write
  - edit
  - ls
  - bash
user-invocable: true
disable-model-invocation: false
---

# cube-sandbox profile configuration

You are configuring kernel-confinement profiles for `cube-sandbox`, the
sandbox-exec launcher. The manifest is the source of truth; the strict
parser is the law. Full reference: `docs/config.md` in the cube-sandbox repo.

## Hard rules

1. **Never invent keys.** Only: `apiVersion` (`cube-sandbox/v1`), `kind`
   (`Harness`), `metadata.name` (`^[a-z][a-z0-9-]*$`),
   `metadata.description`, and `spec.command` / `agentRoot` /
   `agentRootEnv` / `widenToDotParent` / `extraRead` / `extraWrite` /
   `network` (`open` only). An unknown key at ANY level is a hard
   `ConfigException` naming the YAML path (exit 2) — never ignored.
2. **Paths are absolute or `~/`-prefixed**, no `..` segments, no
   trailing `/`, no quotes/newlines. `command` is a string or argv
   list — there is no shell, so no quoting or `$VAR` expansion.
3. **Respect the E10 blocklist.** `~/.ssh`, `~/.gnupg`,
   `~/Library/Keychains` (+ `/private` spellings) can never appear in
   `agentRoot`, `extraRead`, `extraWrite` or `--use-*`: manifest paths
   and `CUBE_SANDBOX_EXTRA_WRITE` are rejected outright (exit 2). Do not
   work around this; ssh remotes failing auth under confinement is the
   designed outcome.
4. **Validate after every edit.** `cube-sandbox sbpl` is the parse check.
   A broken manifest must be caught by you, not at launch time.
5. **Grants come from the user's request.** Add only the folders the
   user asked for; report exactly what you widened.

## Workflow

1. **Locate.** `cube-sandbox list` — presets (`fa`, `omp`, `pi`) plus
   project `.cube-sandbox/<name>.yaml` and user `~/.cube-sandbox/<name>.yaml`.
   Resolution precedence: `--yaml` (inline/stdin) > `--file` >
   project > user > preset. The filename stem is the profile id.
2. **Author.** Prefer scaffolding, then edit:
   ```sh
   cube-sandbox new <name> --command <cmd> --agent-root ~/.<name>
   ```
   It writes `.cube-sandbox/<name>.yaml` (refuses to overwrite) and
   round-trip-verifies the scaffold. Or write the manifest by hand from
   the schema in `docs/config.md` — then validate (step 3).
3. **Validate.**
   ```sh
   cube-sandbox sbpl <name>                          # parse + emit exact kernel profile
   cube-sandbox sbpl <name> --file <path>.yaml       # validate a file in place
   cube-sandbox show <name>                          # resolved rw / ro / denied banner
   ```
   Parse errors name the YAML path (`<file>.spec.command: …`); fix the
   named key, re-run until `sbpl` prints a profile cleanly.
4. **Launch.**
   ```sh
   cube-sandbox launch <name>                  # profile's own command
   cube-sandbox launch <name> -- <cmd…>        # any command under the same boundary
   ```
5. **Probe.** `cube-sandbox probe <name>` self-checks the boundary FROM
   INSIDE the profile (writes outside grants denied, project rw works,
   network open). Exit `0` = confined and working; `1` = broken — do
   not hand back a profile that fails probe.
6. **Service grants.** Add `--use-github` (ro `~/.config/gh`,
   `~/.gitconfig`), `--use-gitlab` (ro `~/.config/glab`,
   `~/.gitconfig`, dedups), `--use-nvm` (ro `~/.nvm`) at run time:
   `cube-sandbox launch <name> --use-github`. Flags union + dedup; unknown
   ones fail loudly listing the catalog. To make grants permanent for a
   profile, put the folders in `extraRead`/`extraWrite` instead.
7. **Report.** File touched, keys changed, grants added (rw vs ro),
   `sbpl` + `probe` results, and how to launch.
