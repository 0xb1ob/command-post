#!/usr/bin/env bash
# Idempotent command-post dependency installer. No arguments.
# Installs runtime tools AGENTS.md expects: muxa, br (beads), treehouse.
# Run once after clone; safe to re-run (muxa refreshes skills/hooks).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${CP_BIN_DIR:-$HOME/.local/bin}"

MUXA_INSTALL_URL="${MUXA_INSTALL_URL:-https://raw.githubusercontent.com/0xb1ob/muxa/main/install.sh}"
BR_INSTALL_URL="${BR_INSTALL_URL:-https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh}"
TREEHOUSE_INSTALL_URL="${TREEHOUSE_INSTALL_URL:-https://kunchenguid.github.io/treehouse/install.sh}"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] warning: %s\n' "$*" >&2; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

on_path() {
  case ":${PATH}:" in
    *:"$1":*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_bin_dir() {
  mkdir -p "$BIN"
  if ! on_path "$BIN"; then
    warn "$BIN is not on PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

require_prereqs() {
  local missing=0
  for cmd in git curl tmux; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "$cmd is required but not found"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install git, curl, and tmux first (muxa needs tmux; all three are used below)"
  fi
}

install_muxa() {
  if command -v muxa >/dev/null 2>&1; then
    log "muxa: $(muxa version 2>/dev/null || echo installed) — refreshing install"
  else
    log "muxa: installing from $MUXA_INSTALL_URL"
  fi

  if curl -fsSL "$MUXA_INSTALL_URL" 2>/dev/null | MUXA_BIN_DIR="$BIN" bash; then
    return 0
  fi

  # muxa repo is private; fall back to gh-authenticated clone when curl 404s.
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local home="${MUXA_HOME:-$HOME/.muxa}"
    log "muxa: curl install failed; trying gh repo clone -> $home"
    if [[ -d "$home/.git" ]]; then
      git -C "$home" fetch --depth 1 origin main
      git -C "$home" merge --ff-only origin/main
    else
      gh repo clone 0xb1ob/muxa "$home" -- --depth 1
    fi
    MUXA_BIN_DIR="$BIN" bash "$home/install.sh"
    return 0
  fi

  die "muxa install failed. Need access to github.com/0xb1ob/muxa (private repo) or set MUXA_INSTALL_URL."
}

install_br() {
  if command -v br >/dev/null 2>&1; then
    log "br: already installed ($(br --version))"
    return 0
  fi

  log "br: installing from beads_rust"
  curl -fsSL "${BR_INSTALL_URL}?$(date +%s)" | bash -s -- --dest "$BIN" --skip-skills --quiet
}

install_treehouse() {
  if command -v treehouse >/dev/null 2>&1; then
    log "treehouse: already installed ($(treehouse --version 2>/dev/null || treehouse -v 2>/dev/null || echo ok))"
    return 0
  fi

  log "treehouse: installing from $TREEHOUSE_INSTALL_URL"
  # treehouse install.sh picks ~/.local/bin when it is on PATH; prepend ours.
  PATH="$BIN:$PATH" sh -c "curl -fsSL '$TREEHOUSE_INSTALL_URL' | sh"
}

verify_tool() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd not found after install (expected on PATH; check $BIN)"
  fi
  log "verified: $cmd -> $(command -v "$cmd")"
}

main() {
  log "command-post deps (cwd $ROOT)"
  require_prereqs
  ensure_bin_dir
  install_muxa
  install_br
  install_treehouse

  # Re-scan PATH so verify sees freshly linked binaries.
  export PATH="$BIN:$PATH"
  verify_tool muxa
  verify_tool br
  verify_tool treehouse

  log "done — next: bin/bootstrap.sh"
}

main "$@"
