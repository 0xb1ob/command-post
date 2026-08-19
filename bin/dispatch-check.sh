#!/usr/bin/env bash
# Warn when a spawn cwd already has a registered muxa worker.
# Orchestrator helper only — does not spawn, lease, or message anyone.
#
# Usage: bin/dispatch-check.sh --cwd PATH
# Exit:  0 clear, 1 collision (promote instead of spawn), 2 usage/error
#
# Override roster source for tests: MUXA_WHO_CMD='cat /path/to/who.txt'
set -euo pipefail

usage() {
  printf 'usage: %s --cwd PATH\n' "$(basename "$0")" >&2
  exit 2
}

CWD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cwd)
      [[ $# -ge 2 ]] || usage
      CWD="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$CWD" ]] || usage

normalize_path() {
  local p="$1"
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
  else
    printf '%s\n' "$p"
  fi
}

TARGET="$(normalize_path "$CWD")"

if ! command -v muxa >/dev/null 2>&1 && [[ -z "${MUXA_WHO_CMD:-}" ]]; then
  printf '[dispatch-check] error: muxa not on PATH\n' >&2
  exit 2
fi

WHO_CMD=(muxa who)
if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
  # shellcheck disable=SC2206
  WHO_CMD=($MUXA_WHO_CMD)
fi

collisions=0
self="${MUXA_WHOAMI:-}"
if [[ -z "$self" ]] && command -v muxa >/dev/null 2>&1 && [[ -z "${MUXA_WHO_CMD:-}" ]]; then
  self="$(muxa whoami 2>/dev/null || true)"
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  [[ -n "$line" ]] || continue
  [[ "$line" == NAME* ]] && continue
  path="${line##* }"
  [[ -n "$path" ]] || continue
  resolved="$(normalize_path "$path")"
  [[ "$resolved" == "$TARGET" ]] || continue
  alias="${line%% *}"
  if [[ -n "$self" && "$alias" == "$self" ]]; then
    continue
  fi
  printf '[dispatch-check] collision: %s already on %s\n' "$alias" "$TARGET" >&2
  printf '%s\n' "$line"
  if [[ "$line" == *" ghost "* || "$line" == *$'\t'ghost$'\t'* ]]; then
    printf '[dispatch-check] %s is ghost — unregister it; do not promote\n' "$alias" >&2
  else
    printf '[dispatch-check] same worktree still held → muxa send %s to promote; do not muxa spawn\n' "$alias" >&2
  fi
  collisions=$((collisions + 1))
done < <("${WHO_CMD[@]}")

if [[ "$collisions" -gt 0 ]]; then
  printf '[dispatch-check] %d registered worker(s) on this cwd — promote, do not duplicate spawn\n' "$collisions" >&2
  exit 1
fi

printf '[dispatch-check] clear: no other registered worker on %s\n' "$TARGET"
exit 0
