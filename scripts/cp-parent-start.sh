#!/usr/bin/env bash
# Start the command-post parent in the pane this script is already running in.
#
# Boundary: this script never creates a pane or a tmux session. AGENTS.md says
# command-post may never call tmux directly, and muxa has no "start a root"
# primitive, so making the pane is the operator's login item — see
# share/launchd/com.command-post.parent.plist.example and
# docs/always-on-parent.md. This script is the part that is command-post's: it
# checks the home, reports host readiness, and execs the agent CLI.
#
# An always-on parent is preferred over on-demand spawn: a mention that arrives
# with no parent must not be queued and replayed later, so "no parent" should
# mean "the laptop is off", not "nobody started it".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP_HOME="${CP_HOME:-$ROOT}"
export CP_HOME

if [[ -z "${TMUX:-}" ]]; then
  printf '[cp-parent-start] error: not inside a tmux pane.\n' >&2
  printf '[cp-parent-start] This script does not create panes (AGENTS.md boundary).\n' >&2
  printf '[cp-parent-start] Start it from a login item, e.g.\n' >&2
  printf '[cp-parent-start]   tmux new-session -d -s command-post -c %s %s\n' "$CP_HOME" "$0" >&2
  printf '[cp-parent-start] See docs/always-on-parent.md\n' >&2
  exit 2
fi

if [[ -n "$(muxa parent 2>/dev/null || true)" ]]; then
  printf '[cp-parent-start] error: this pane is a muxa child — a parent must be a root.\n' >&2
  exit 2
fi

if [[ ! -d "$CP_HOME/.beads" ]]; then
  printf '[cp-parent-start] error: %s has no .beads — run bin/install.sh in the home first.\n' "$CP_HOME" >&2
  exit 2
fi

# Advisory: never fatal. A parent that will not start is worse than a parent
# with a missing worker CLI, and doctor exits 2 on host gaps by design.
"$ROOT/bin/cp" doctor >/dev/null 2>&1 || \
  printf '[cp-parent-start] warning: bin/cp doctor reported gaps — run it for detail.\n' >&2

cd "$CP_HOME"
AGENT_CMD=("${CP_PARENT_CMD:-claude}")
if [[ -n "${CP_PARENT_CMD:-}" ]]; then
  # shellcheck disable=SC2206 # deliberate word splitting: CP_PARENT_CMD is argv
  AGENT_CMD=(${CP_PARENT_CMD})
fi
if ! command -v "${AGENT_CMD[0]}" >/dev/null 2>&1; then
  printf '[cp-parent-start] error: %s not on PATH (set CP_PARENT_CMD).\n' "${AGENT_CMD[0]}" >&2
  exit 2
fi
printf '[cp-parent-start] home=%s starting %s\n' "$CP_HOME" "${AGENT_CMD[*]}" >&2
exec "${AGENT_CMD[@]}"
