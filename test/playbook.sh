#!/usr/bin/env bash
# Playbook contract checks for AGENTS.md after command-post#18–#24.
# Not a live dispatch E2E. Run from the command-post repo: test/playbook.sh
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
has 'muxa dispatch --cwd "$worktree" --brief-file' "first brief is muxa dispatch --cwd --brief-file"
has "--brief-file" "brief is --brief-file, not a positional string"
has "stdin also works" "stdin is an allowed brief transport"
has "never a positional" "first brief is never a positional string"
has 'state: dispatched' "stdout state is dispatched"
has "queued, not received" "playbook distinguishes queued from received"
has "state=dispatched → queued" "state=dispatched means queued"
has "[muxa] from=broker" "never-ready path is broker mail"
has "muxa tail NAME" "receipt verify is muxa tail"
has "one \`muxa tail NAME\`" "receipt is one muxa tail, not a loop"
has "Do not loop tail" "playbook forbids looping muxa tail"
has "Branch: \${branch}" "brief carries a branch receipt token"
has "have a brief, so the path is \`muxa dispatch\`" "jobs with a brief use dispatch, not spawn"
has "do not muxa dispatch, do not treehouse get --lease" "promote-not-spawn forbids a second dispatch"
has "muxa kill NAME|ID" "teardown pane removal is muxa kill"
has "treehouse return --force <worktree>" "teardown returns the lease with --force"
has "from outside the worktree" "treehouse return is from outside the worktree"
has "belongs to another repo" "stale-clone recovery names belongs to another repo"
has "Parent only; finished worker only; outside the worktree" "teardown actor and place are constrained"
has "there is nothing to trigger manually" "delivery is the broker's; nothing to trigger manually"
lacks "muxa unregister" "muxa unregister is gone (command does not exist)"
lacks "muxa deliver" "muxa deliver is gone (delivery is the broker's alone)"
lacks "### Named temporary exception: \`tmux kill-pane\` at teardown" "named tmux kill-pane exception is gone"
lacks "tmux kill-pane" "command-post does not call tmux kill-pane"
lacks "muxa 0.3.0 has spawn and unregister only" "stale muxa 0.3.0 exception copy is gone"

lacks "Brief immediately with \`muxa send\`" "no spawn-then-send choreography"
lacks "Do not leave a new pane unbriefed" "ordering-only prose is gone"
lacks "muxa send --json <alias>" "first brief is not muxa send --json"
lacks '`muxa jobs`' "does not resurrect muxa jobs"
lacks '`muxa preflight`' "does not resurrect muxa preflight"

# Zero tmux pane commands in the playbook, bin/cp, and this repo's tests.
# Mentions of the word tmux ("do not call tmux") are allowed; quoted
# contract needles in this file are not invocations.
tmux_hits="$(grep -nE '^[^"#]*tmux[[:space:]]+(kill-pane|send-keys|list-panes|capture-pane|display-message|new-window|split-window)' \
  "$AGENTS" "$ROOT/bin/cp" "$ROOT"/test/*.sh || true)"
if [[ -n "$tmux_hits" ]]; then
  fail "zero tmux pane commands in playbook, bin/cp, and tests ($tmux_hits)"
else
  ok "zero tmux pane commands in playbook, bin/cp, and tests"
fi

# bin/cp consumes who --json; it must not call dispatch/spawn/kill/send.
# Strip comments and quoted strings so policy printf text is not an invocation.
cp_muxa_hits="$(sed -E "s/#.*//; s/\"[^\"]*\"//g; s/'[^']*'//g" "$ROOT/bin/cp" | grep -nE 'muxa[[:space:]]+(dispatch|spawn|kill|send|unregister|tail)([[:space:]]|$)' || true)"
if [[ -n "$cp_muxa_hits" ]]; then
  fail "bin/cp does not invoke muxa dispatch/spawn/kill/send ($cp_muxa_hits)"
else
  ok "bin/cp does not invoke muxa dispatch/spawn/kill/send"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
