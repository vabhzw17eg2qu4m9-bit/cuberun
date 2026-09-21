#!/bin/sh
# install.sh — one-line installer for the cube-sandbox CLI.
#
#   curl -fsSL "https://github.com/vabhzw17eg2qu4m9-bit/cuberun/releases/latest/download/install.sh" | sh
#
# What it does:
#   1. Detects OS and architecture.
#   2. Downloads the matching cube-sandbox bundle from a GitHub Release
#      (a single static AOT-compiled binary, no shared libraries).
#   3. Installs it under ~/.cube-sandbox/bin and ensures that is on PATH.
#
# Install a specific version:
#   ... | sh -s -- v0.2.0          (or:  sh install.sh 0.2.0)
#   ... | CUBE_SANDBOX_VERSION=v0.2.0 sh
#
# The repository is public — no token needed. CUBE_SANDBOX_GITHUB_TOKEN is
# still honored (optional) for API rate limits or private forks:
#   export CUBE_SANDBOX_GITHUB_TOKEN=ghp_...
#
# Environment overrides:
#   CUBE_SANDBOX_INSTALL_DIR    installation root (default: ~/.cube-sandbox)
#   CUBE_SANDBOX_VERSION        version to install (default: latest release)
#   CUBE_SANDBOX_GITHUB_TOKEN   optional auth token (rate limits / private forks)
#   CUBE_SANDBOX_DOWNLOAD_BASE  artifact root override (mirrors / tests)
#
# POSIX sh only (dash-safe): no [[ ]], arrays, or pipefail.

set -eu

REPO="vabhzw17eg2qu4m9-bit/cuberun"
BINARY="cube-sandbox"

# ── Output helpers ──────────────────────────────────────────────────────────
info() { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*" >&2; }
err() { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; }

# ── 1. Detect OS/arch ───────────────────────────────────────────────────────
os=""
case "$(uname -s)" in
  Darwin*) os=macos ;;
  Linux*) os=linux ;;
  *)
    err "unsupported OS: $(uname -s). This installer covers macOS today."
    exit 1
    ;;
esac

arch=""
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *)
    err "unsupported architecture: $(uname -m)."
    exit 1
    ;;
esac

asset="cube-sandbox-${os}-${arch}.tar.gz"
# Shipped prebuilts today — fail loudly and say what exists. Add combos to
# the accepted list as release assets appear.
case "${os}-${arch}" in
  macos-arm64) ;;
  *)
    err "no prebuilt ${asset} yet."
    err "shipped today: cube-sandbox-macos-arm64 (macOS, Apple Silicon);"
    err "linux-x64 and macos-x64 are not shipped yet. Build from source:"
    err "  git clone https://github.com/${REPO}.git && cd cuberun && just build"
    exit 1
    ;;
esac

# ── 2. Resolve version ──────────────────────────────────────────────────────
# CUBE_SANDBOX_DOWNLOAD_BASE overrides the artifact root (default: GitHub
# Releases) — used by mirrors and by the installer's own tests.
version="${1:-${CUBE_SANDBOX_VERSION:-}}"
if [ -n "$version" ]; then
  case "$version" in
    v*) ;;
    *) version="v$version" ;;
  esac
  # Tagged download URL: releases/download/vX.Y.Z/<asset>
  download_base="${CUBE_SANDBOX_DOWNLOAD_BASE:-https://github.com/${REPO}/releases/download/${version}}"
  display_version="$version"
else
  # Latest: GitHub's redirect endpoint needs no tag lookup.
  download_base="${CUBE_SANDBOX_DOWNLOAD_BASE:-https://github.com/${REPO}/releases/latest/download}"
  display_version="latest"
fi

# ── 3. Optional auth (private repo) ─────────────────────────────────────────
fetch() {
  # fetch <url> <output-file> — curl or wget, with optional bearer auth.
  if command -v curl >/dev/null 2>&1; then
    if [ -n "${CUBE_SANDBOX_GITHUB_TOKEN:-}" ]; then
      curl -fSL --progress-bar -H "Authorization: Bearer ${CUBE_SANDBOX_GITHUB_TOKEN}" \
        "$1" -o "$2"
    else
      curl -fSL --progress-bar "$1" -o "$2"
    fi
  elif command -v wget >/dev/null 2>&1; then
    if [ -n "${CUBE_SANDBOX_GITHUB_TOKEN:-}" ]; then
      wget --progress=bar -q --header="Authorization: Bearer ${CUBE_SANDBOX_GITHUB_TOKEN}" \
        -O "$2" "$1"
    else
      wget --progress=bar -q -O "$2" "$1"
    fi
  else
    err "neither curl nor wget is available."
    exit 1
  fi
}

# ── 4. Download and verify the archive ──────────────────────────────────────
tmpdir="$(mktemp -d 2>/dev/null || mktemp -d -t cube-sandbox-install)"
trap 'rm -rf "$tmpdir"' EXIT

info "Downloading cube-sandbox for ${os}-${arch} (${display_version})..."
archive="$tmpdir/$asset"
if ! fetch "$download_base/$asset" "$archive"; then
  err "download failed: $download_base/$asset"
  if [ -z "${CUBE_SANDBOX_GITHUB_TOKEN:-}" ]; then
    err "not authenticated — for rate limits or private forks export"
    err "CUBE_SANDBOX_GITHUB_TOKEN and retry."
  elif [ -n "$version" ]; then
    err "check that release ${version} exists and has a ${asset} asset."
  fi
  exit 1
fi

# Best-effort checksum verification: a missing checksum file or a missing
# sha256 utility must not block the install; a mismatch is fatal.
checksums="$tmpdir/cube-sandbox-checksums.sha256"
if fetch "$download_base/cube-sandbox-checksums.sha256" "$checksums" 2>/dev/null &&
  [ -s "$checksums" ]; then
  expected="$(grep " ${asset}\$" "$checksums" | head -n 1 | cut -d' ' -f1)"
  if [ -n "$expected" ]; then
    actual=""
    if command -v sha256sum >/dev/null 2>&1; then
      actual="$(sha256sum "$archive" | cut -d' ' -f1)"
    elif command -v shasum >/dev/null 2>&1; then
      actual="$(shasum -a 256 "$archive" | cut -d' ' -f1)"
    fi
    if [ -n "$actual" ]; then
      if [ "$actual" != "$expected" ]; then
        err "checksum mismatch for ${asset}: expected ${expected}, got ${actual}."
        exit 1
      fi
      ok "Checksum verified."
    fi
  fi
fi

# ── 5. Install the binary ───────────────────────────────────────────────────
install_root="${CUBE_SANDBOX_INSTALL_DIR:-$HOME/.cube-sandbox}"
install_bin="$install_root/bin"
mkdir -p "$install_bin"

mkdir -p "$tmpdir/extract"
tar -xzf "$archive" -C "$tmpdir/extract"

src="$tmpdir/extract/cube-sandbox"
if [ ! -f "$src/$BINARY" ]; then
  err "archive is missing expected layout (cube-sandbox/cube-sandbox)."
  exit 1
fi

cp "$src/$BINARY" "$install_bin/$BINARY"
chmod +x "$install_bin/$BINARY"

# macOS quarantine / signature hardening: downloaded executables are tagged
# by Gatekeeper and killed on launch unless the quarantine attribute is
# removed; an ad-hoc re-sign makes the binary runnable from any directory
# on Apple Silicon.
if [ "$(uname -s)" = "Darwin" ]; then
  if command -v xattr >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$install_bin/$BINARY" 2>/dev/null || true
  fi
  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - "$install_bin/$BINARY" 2>/dev/null || true
  fi
fi

# Record the installed version for idempotency/debugging.
printf '%s\n' "$display_version" > "$install_root/version.txt"

ok "Installed $install_bin/$BINARY"

# ── 6. Ensure the bin directory is on PATH ──────────────────────────────────
case ":${PATH}:" in
  *":$install_bin:") ok "'$BINARY' is already on PATH." ;;
  *)
    warn "'$BINARY' is not on PATH yet. Add it with:"
    # The literal $PATH belongs in the rc file (expands at shell startup).
    # shellcheck disable=SC2016
    printf '\n  export PATH="%s:$PATH"\n\n' "$install_bin"

    shell_rc=""
    fish_rc="no"
    case "${SHELL:-}" in
      */zsh) shell_rc="$HOME/.zshrc" ;;
      */bash) shell_rc="$HOME/.bashrc" ;;
      */fish)
        shell_rc="$HOME/.config/fish/config.fish"
        fish_rc="yes"
        ;;
    esac
    if [ -n "$shell_rc" ]; then
      mkdir -p "$(dirname "$shell_rc")"
      if [ -f "$shell_rc" ] && grep -qF "$install_bin" "$shell_rc" 2>/dev/null; then
        ok "$install_bin is already referenced in $shell_rc"
      elif [ "$fish_rc" = "yes" ]; then
        printf '\n# cube-sandbox CLI PATH\nfish_add_path -g "%s"\n' "$install_bin" >> "$shell_rc"
        ok "Added $install_bin to $shell_rc (open a new terminal, or restart fish)."
      else
        # The literal $PATH belongs in the rc file (expands at shell startup).
        # shellcheck disable=SC2016
        printf '\n# cube-sandbox CLI PATH\nexport PATH="%s:$PATH"\n' "$install_bin" >> "$shell_rc"
        ok "Added $install_bin to $shell_rc (open a new terminal, or source it)."
      fi
    fi
    ;;
esac

# ── 7. Smoke-test the installed binary ──────────────────────────────────────
# Timeout-guarded: a smoke that cannot hang beats a smoke that sometimes
# proves the point.
smoke_rc=0
smoke_out=""
if command -v timeout >/dev/null 2>&1; then
  smoke_out="$(timeout 30 "$install_bin/$BINARY" --version 2>&1)" || smoke_rc=$?
else
  smoke_out="$("$install_bin/$BINARY" --version 2>&1)" || smoke_rc=$?
fi
if [ "$smoke_rc" -eq 0 ] && [ -n "$smoke_out" ]; then
  ok "$smoke_out"
else
  warn "installed binary failed the smoke test (rc=$smoke_rc): $smoke_out"
fi

printf '\n'
ok "Installation complete. Try:"
printf '\n  cube-sandbox list\n  cube-sandbox probe pi\n\n'
