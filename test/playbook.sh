#!/usr/bin/env bash
# Fail-closed playbook checks for muxa dispatch adoption (command-post#15).
# Run from the command-post repo: test/playbook.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS="$ROOT/AGENTS.md"
failed=0
n=0

ok() {
  n=$((n + 1))
  printf 'ok %d - %s\n' "$n" "$1"
}

fail() {
  n=$((n + 1))
  failed=$((failed + 1))
  printf 'not ok %d - %s\n' "$n" "$1"
}

has() {
  local needle="$1" label="$2"
  if grep -F -q -- "$needle" "$AGENTS"; then
    ok "$label"
  else
    fail "$label (missing $(printf %q "$needle"))"
  fi
}

lacks() {
  local needle="$1" label="$2"
  if grep -F -q -- "$needle" "$AGENTS"; then
    fail "$label (still has $(printf %q "$needle"))"
  else
    ok "$label"
  fi
}

has "muxa dispatch" "first brief is muxa dispatch"
has "--brief-file" "brief is --brief-file, not a positional string"
has 'state: dispatched' "stdout state is dispatched"
has "queued, not received" "playbook distinguishes queued from received"
has "[muxa] from=broker" "never-ready path is broker mail"
has "muxa tail NAME" "receipt verify is muxa tail"
has "Branch: \${branch}" "brief carries a branch receipt token"
has "do not muxa dispatch, do not treehouse get --lease" "promote-not-spawn forbids a second dispatch"
has "### Named temporary exception: \`tmux kill-pane\` at teardown" "teardown exception subsection remains"
has "muxa 0.3.0 has spawn and unregister only" "teardown exception text is unchanged"

lacks "Brief immediately with \`muxa send\`" "no spawn-then-send choreography"
lacks "Do not leave a new pane unbriefed" "ordering-only prose is gone"
lacks "muxa send --json <alias>" "first brief is not muxa send --json"
lacks '`muxa jobs`' "does not resurrect muxa jobs"
lacks '`muxa preflight`' "does not resurrect muxa preflight"

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
