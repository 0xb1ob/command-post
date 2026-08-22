#!/usr/bin/env bash
# Project-scoped session-start for command-post roots. Invoked by
# .claude/settings.json and .cursor/hooks.json — never required for spawned workers.
set -euo pipefail
BIN="${CP_BIN_DIR:-$HOME/.local/bin}"
MUXA_HOME="${MUXA_HOME:-$HOME/.muxa}"
export PATH="$BIN:$MUXA_HOME/bin:$PATH"
muxa_bin="$(command -v muxa || true)"
[[ -n "$muxa_bin" ]] || exit 0
if [ -n "${MUXA_HOOK_LOG:-}" ]; then
  printf '%s pane=%s cwd=%s args=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "${TMUX_PANE:-}" \
    "$PWD" \
    "$*" >>"$MUXA_HOOK_LOG"
fi
exec "$muxa_bin" hook "$@"
