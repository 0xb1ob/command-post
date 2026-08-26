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
has "### Broker parent turns" "broker parent turns section exists"
has "dispatch refused:" "dispatch refused shape is documented"
has "composer holds foreign input" "foreign composer refusal is named"
has "teardown is wrong" "dispatch refused forbids teardown"
has "dispatch unsubmitted:" "dispatch unsubmitted shape is documented"
has 'Proceed with the job in the brief above.' "unsubmitted recovery nudge is documented"
has "Do not check broker \`pending/\`" "stale pending/ queue check is forbidden"
lacks "dispatch unconfirmed:" "old dispatch unconfirmed broker turn is gone"
has "muxa tail NAME" "receipt verify is muxa tail"
has "one \`muxa tail NAME\`" "receipt is one muxa tail, not a loop"
has "Do not loop tail" "playbook forbids looping muxa tail"
has "Branch: \${branch}" "brief carries a branch receipt token"
has "have a brief, so the path is \`muxa dispatch\`" "jobs with a brief use dispatch, not spawn"
has "bin/cp lease --project" "manual lease uses bin/cp lease"
has "do not muxa dispatch, do not treehouse get --lease" "promote-not-spawn forbids a second dispatch"
has "muxa kill NAME|ID" "teardown pane removal is muxa kill"
has "treehouse return --force <worktree>" "teardown returns the lease with --force"
has "from outside the worktree" "treehouse return is from outside the worktree"
has "belongs to another repo" "stale-clone recovery names belongs to another repo"
has "Parent only; finished worker only; outside the worktree" "teardown actor and place are constrained"
has "there is nothing to trigger manually" "delivery is the broker's; nothing to trigger manually"

has "bin/cp jobs reported" "playbook requires jobs reported on worker envelope"
has "### Worker envelope" "worker envelope section exists"
has "before relay and before teardown" "jobs reported is before relay and teardown"
has "delivery:pr" "delivery:pr hold rule is documented"
has "Status shows **\`held\`**" "held phase is named in playbook"
has "### Stalled and held workers" "stalled and held workers section exists"
has "forgotten \`jobs reported\`" "stalled requires no reported_at"
has "Not a fault" "held is explicitly not a fault"
has "Differs from **\`waiting\`**" "held differs from waiting and done"

# Status block contract (operator-facing parent turns)
has "## Status block" "status block section exists"
has "operator-facing turn" "status block applies to operator-facing turns"
has "always rendered" "all four tables always render"
has "**In progress**" "in progress table is defined"
has "**Blocked**" "blocked table is defined"
has "**Awaiting you**" "awaiting you table is defined"
has "**Shipped**" "shipped table is defined"
has "**Shipped bound:**" "shipped table has an explicit recency cap"
has "max **five** rows" "shipped table is capped at five rows"
has "not the closed backlog" "shipped table excludes full br history"
has "### Shipped" "shipped table appears in the status block example"
has "Self-describing rows" "rows must be self-describing"
has "never bare" "bare br ids are forbidden in the block"
has "Route human blockers to table 3" "human blockers go to awaiting you"
has "dependency-blocked" "human vs br-dep distinction is documented"
has "When required:" "when the block is required is stated"
has "When omitted:" "when the block may be omitted is stated"
has "Keep turns short" "status block coexists with short parent turns"
has "Never paste worker dumps into the block" "status block is not for worker dumps"
has "This is not \`bin/cp status\`" "status block is distinct from bin/cp status"
has "[Status block](#status-block)" "parent job links to status block section"
has "Awaiting you](#status-block) counts as such a decision" "ping-pong rule ties to awaiting you rows"
has "Human decision = Awaiting you only" "human-blocked jobs appear only in awaiting you"
has "never also in **Blocked**" "human-blocked jobs must not duplicate in blocked table"
has "**Type** is required on every **Awaiting you** row" "awaiting you rows require decision type"
has "\`approval\`" "approval decision type is defined"
has "\`design\`" "design decision type is defined"
has "\`authorization\`" "authorization decision type is defined"

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

lacks "The operator currently forbids the claude CLI for workers" "claude ban sentence is removed from AGENTS.md"
has "data/routing.tsv" "playbook points at data/routing.tsv for routing"
has "bin/cp doctor" "playbook mentions bin/cp doctor"
has "missing CLI exits 2" "playbook documents pre-lease CLI probe"

# Parallel PRs and merge discipline (command-post#78)
has "Parallel PRs, one base" "parallel PRs from one base section exists"
has "rebase onto the merged tip" "second PR must rebase onto merged tip"
has "re-run the **full** suite" "full suite re-run before merge is required"

# Teardown: merged PR with auto-deleted head (command-post#78)
has "auto-deleted head" "merged auto-deleted head teardown recovery exists"
has "git diff <branch> origin/main" "two-dot diff for merged branch verification"

# br list verification cap (command-post#74 / #78)
has "--limit 0" "br list limit 0 for verification is documented"
has "caps at 50" "br list 50-row cap is named"

# Memory scope (command-post#78)
has "Fresh-home test" "fresh-home test routes knowledge to contract"
has "operating-knowledge.md" "operating knowledge report is linked from contract"
has "residue only" "learnings is residue-only in memory section"

lines="$(wc -l < "$AGENTS" | tr -d ' ')"
if [[ "$lines" -le 480 ]]; then
  ok "AGENTS.md is ≤480 lines (target ~400; got $lines)"
else
  fail "AGENTS.md is ≤480 lines (got $lines; target ~400)"
fi

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

# check/jobs consume who --json only. dispatch/teardown wrap muxa (call
# dispatch, tail, kill) and must not reimplement them. Follow-up mail is
# still the orchestrator's muxa send — this CLI must not send, spawn, or
# unregister. Strip comments and quoted strings so policy printf text is
# not an invocation.
cp_muxa_hits="$(grep -rnE 'muxa[[:space:]]+(spawn|send|unregister)([[:space:]]|$)' "$ROOT/internal/cp" 2>/dev/null | grep -v '_test.go' || true)"
if [[ -n "$cp_muxa_hits" ]]; then
  fail "bin/cp does not invoke muxa spawn/send/unregister ($cp_muxa_hits)"
else
  ok "bin/cp does not invoke muxa spawn/send/unregister"
fi

grep -F -q 'dispatch_cmd=(muxa dispatch)' "$ROOT/scripts/cp-legacy.bash" \
  || grep -F -q 'muxa dispatch' "$ROOT/internal/cp/dispatch.go" \
  && ok "bin/cp dispatch calls muxa dispatch" \
  || fail "bin/cp dispatch calls muxa dispatch"
grep -F -q 'muxa tail' "$ROOT/internal/cp/dispatch.go" \
  || grep -F -q 'muxa tail' "$ROOT/scripts/cp-legacy.bash" \
  && ok "bin/cp dispatch calls muxa tail" \
  || fail "bin/cp dispatch calls muxa tail"
grep -F -q 'muxa kill' "$ROOT/internal/cp/teardown.go" \
  || grep -F -q 'muxa kill' "$ROOT/scripts/cp-legacy.bash" \
  && ok "bin/cp teardown calls muxa kill" \
  || fail "bin/cp teardown calls muxa kill"

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
