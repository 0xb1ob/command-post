#!/usr/bin/env bash
# Dispatch helper for command-post.
#
#   bin/cmdp check --project NAME [--base BRANCH] WORKTREE [WORKTREE...]
#   bin/cmdp lease --project NAME
#   bin/cmdp jobs add|set|done|list ...
#   bin/cmdp artifact path|add|get ...
#   bin/cmdp gate ID [--model M]
#   bin/cmdp doctor [--json]
#   bin/cmdp dispatch --project NAME --br-id ID [--name ALIAS] [--template TNAME]
#                   [--task-file FILE] [-- CMD...]
#   bin/cmdp teardown ID [--research]
#   bin/cmdp status [--json] [--html] [--serve [--port N]] [--origin ID]
#
# check: fail-closed dispatch precheck. Does not dispatch, send mail, write
# jobs, or wrap br.
# dispatch / teardown: mechanize the pre-dispatch checklist and teardown.
# They wrap muxa, treehouse, and git. They do not call tmux and do not
# reimplement muxa dispatch (they call it). state=dispatched means the
# brief is queued, not received. Never-ready ([muxa] from=broker) is the
# orchestrator's job — these commands do not retry.
#
# Exit:
#   0  ok
#   1  check failed (wrong clone, git preflight, or promote-not-spawn),
#      or jobs mutation refused (unknown id, duplicate add, …)
#   2  usage / missing tools
#
# Checks:
#   1. Canonical clone is <command-post-home>/projects/<name> — not ~/name,
#      not a nested directory of another git, not a worktree of another clone.
#   2. Git preflight (no tmux, no muxa): the clone's primary checkout sits on
#      the base branch (--base, else origin/HEAD, else main), and each
#      WORKTREE is a linked worktree of that clone's .git. Relative WORKTREE
#      paths resolve against the clone, not this process cwd. The distinctive
#      wrong-clone line is "belongs to another repo".
#   3. Occupancy from muxa who --json state=idle|busy|ghost (status key is
#      gone). idle or busy occupying a target worktree → promote-not-spawn
#      (live worker; muxa send, do not dispatch, do not lease). ghost →
#      occupied cwd, dead worker: do not promote, do not dispatch (muxa kill
#      NAME|ID for a dead pane, or restart the CLI in that pane). Anything
#      else → fail closed. Occupancy is muxa dispatch --cwd's warning (same
#      as muxa spawn --cwd); this checker reads muxa who --json and applies
#      command-post policy. It does not call muxa dispatch or muxa spawn. It
#      does not call tmux. Do not parse the human who table.
#
# jobs: runtime worker ⟷ worktree ⟷ branch map, keyed by br issue id.
# Durable kind / delivery / status / PR URL live on the br issue — this
# command rejects those fields (they existed on muxa jobs only because
# that CLI required them). State: $CP_HOME/state/jobs.tsv (gitignored).
# Does not call tmux; pane facts stay on muxa who --json / dispatch stdout.
#
# artifact: br-comment store for research→implement handoff. path prints
# $CP_HOME/state/artifacts/<id>/report.md (gitignored; teardown cleans).
# add writes the file as a comment prefixed with artifact:v1 (body in br;
# never printed). get prints the newest artifact:v1 body with the marker
# stripped. br always uses the home tracker (--db); fail-closed if
# $CP_HOME has no .beads (do not init a second database from a worktree).
#
# gate: headless quality gate for a research artifact (no pane, no lease,
# no mail). Extracts via artifact get (never br show — that inlines
# comment bodies), reviews against templates/gate-rubric.md, records a
# short gate:v1 comment. Stdout JSON always includes reasons and cause
# (null on pass/revise; policy|operational|operational_persistent on escalate); revisions when
# verdict=revise. Bloated reasons/revisions are truncated (ellipsis) so
# the JSON stays a few hundred words — never the artifact body.
# Policy (flag=yes → escalate; one revise max) is enforced here, not in
# the prompt. Default reviewer is the cursor agent CLI (--print --mode
# ask --output-format text --model composer-2.5-fast); override the whole
# command with CP_GATE_CMD (stdin → stdout). Exit 0=pass, 10=revise,
# 20=escalate; pass does not close the issue or authorize implementation.
# Escalate cause: policy = rubric/flags/attempt cap; operational =
# reviewer output unparseable after one in-run retry (re-run gate once);
# operational_persistent = same on the immediately prior gate run (model
# likely cannot meet the parse contract — swap --model or surface to caller).
#
# status: read-only fleet snapshot ({v,generated_at,home,broker,nodes[],edges[]},
# a human table, --html self-contained page, or --serve foreground localhost
# dashboard). --serve is opt-in blocking HTTP on 127.0.0.1; not a daemon.
# Composes
# muxa who --json, muxa broker status (exactly once; degrades to ok:false
# rather than aborting), state/jobs.tsv, and br list --json (never br
# show/comments list — AGENTS.md:151-153). Join precedence per pane:
# jobs.worker -> jobs.worktree -> git branch == a br id -> untracked.
# Timestamp prefers jobs.tsv dispatched_at (time_source:"dispatched_at");
# legacy 4-column rows fall back to br.updated_at (time_source:
# "br_updated_at"). Phase stalled: pane idle + br open/in_progress +
# stamped dispatched_at older than CP_STATUS_STALL_SEC (default 600s — see
# DEFAULT_STATUS_STALL_SEC) and no reported_at; legacy rows without
# dispatched_at never stall. Phase held: idle + open br + reported_at
# (worker finished and deliberately kept for PR/CI follow-up).
# Read-only: mutates nothing, never calls tmux.
#
# Command-post home is this script's repo root (from the script location,
# never $PWD), or CP_HOME if set.
# Test overrides (not for live dispatch): MUXA_WHO_CMD, MUXA_WHOAMI,
# BR_SHOW_CMD, BR_DB, CP_JOBS_FILE, CP_GATE_CMD, MUXA_BROKER_CMD,
# BR_LIST_CMD, BR_BLOCKED_CMD, CP_STATUS_NOW, CP_STATUS_STALL_SEC. dispatch/teardown call muxa
# and treehouse on PATH so tests can shim them.
set -euo pipefail

PROG="${BASH_SOURCE[0]}"
ROOT="$(cd "$(dirname "$PROG")/.." && pwd)"
CP_HOME="${CP_HOME:-$ROOT}"

DEFAULT_GATE_MODEL="composer-2.5-fast"
# Stall detection (bin/cmdp status): idle + open br + stamped dispatched_at
# older than this many seconds and no reported_at. 600s (10m) default —
# the vivid-fox incident sat 24m with an empty composer after the CLI ate
# the paste post-receipt; healthy workers mail within minutes; finished
# workers get reported_at when the parent processes the envelope and
# render as held, not stalled.
DEFAULT_STATUS_STALL_SEC=600

# Shipped role defaults (same argv as AGENTS.md). Local data/routing.tsv overrides.
SHIPPED_RESEARCHER=(agent --model cursor-grok-4.6-high-fast)
SHIPPED_IMPLEMENTER=(agent --model composer-2.5-fast)
SHIPPED_GATE_REVIEWER=(agent --model composer-2.5-fast)

# In-process memoization only — no persistent CLI discovery cache.
# Bash 3.2 compatible (no associative arrays): dynamic variable names.
cmd_v_path() {
  local bin="$1" p var safe
  safe="${bin//[^a-zA-Z0-9_]/_}"
  var="_CP_CMD_V_${safe}"
  eval "p=\${${var}-}"
  if [[ -n "$p" ]]; then
    printf '%s\n' "$p"
    return 0
  fi
  p="$(command -v "$bin" 2>/dev/null || true)"
  eval "${var}=\$p"
  printf '%s\n' "$p"
}

usage() {
  printf 'usage: %s check --project NAME [--base BRANCH] WORKTREE [WORKTREE...]\n' "$PROG" >&2
  printf '       %s lease --project NAME\n' "$PROG" >&2
  printf '       %s jobs add|set|reported|done|list ...\n' "$PROG" >&2
  printf '       %s artifact path|add|get ...\n' "$PROG" >&2
  printf '       %s gate ID [--model M]\n' "$PROG" >&2
  printf '       %s doctor [--json]\n' "$PROG" >&2
  printf '       %s dispatch --project NAME --br-id ID [--name ALIAS] [--template TNAME] [--task-file FILE] [-- CMD...]\n' "$PROG" >&2
  printf '       %s teardown ID\n' "$PROG" >&2
  printf '       %s status [--json] [--html] [--serve [--port N]] [--origin ID]\n' "$PROG" >&2
  exit 2
}

usage_status() {
  printf 'usage: %s status [--json] [--html] [--serve [--port N]] [--origin ID]\n' "$PROG" >&2
  printf '\n' >&2
  printf 'Read-only fleet snapshot composed from muxa who --json, muxa broker\n' >&2
  printf 'status, state/jobs.tsv, and br list --json. No daemon, no new\n' >&2
  printf 'persistence. --serve is an opt-in foreground localhost listener.\n' >&2
  printf 'Never calls tmux; never br show.\n' >&2
  printf '\n' >&2
  printf 'Test overrides (not for live use): MUXA_WHO_CMD, MUXA_BROKER_CMD,\n' >&2
  printf 'MUXA_TAIL_CMD, BR_LIST_CMD, BR_BLOCKED_CMD, CP_JOBS_FILE, BR_DB, CP_STATUS_NOW,\n' >&2
  printf 'CP_STATUS_STALL_SEC.\n' >&2
  printf '\n' >&2
  printf 'Stdout (--json): {v, generated_at, home, broker, nodes[], edges[]}.\n' >&2
  printf 'Stdout (--html): self-contained HTML snapshot with the JSON embedded.\n' >&2
  printf 'Stdout (--serve): prints http://127.0.0.1:PORT/ then blocks (default 8765).\n' >&2
  printf 'Without flags: a human-readable table with a BROKER summary line.\n' >&2
  printf '--origin ID: same tables filtered to that jobs.tsv origin only;\n' >&2
  printf 'cross-origin br dep blockers render blocked without naming the blocker\n' >&2
  printf '(see reports/origin-scoping.md).\n' >&2
}

usage_dispatch() {
  printf 'usage: %s dispatch --project NAME --br-id ID [--name ALIAS] [--template TNAME] [--task-file FILE] [-- CMD...]\n' "$PROG" >&2
  printf '       default CMD: from data/routing.tsv or shipped implementer default\n' >&2
  printf '       --template research uses the researcher role default\n' >&2
  printf '       worker CLI is probed before lease; missing CLI exits 2 (see bin/cmdp doctor)\n' >&2
  printf '       stdout: one JSON object {br_id,worker,worktree,branch,state,receipt}\n' >&2
  printf '       state=dispatched means the brief is queued, not received.\n' >&2
  printf '       receipt=unconfirmed with state=dispatched is a valid success — wait for mail; never re-dispatch.\n' >&2
  printf '       claude panes: receipt=unknown replaces unconfirmed (too-early-to-tell, not not-received) — same rule, wait for mail.\n' >&2
}

usage_teardown() {
  printf 'usage: %s teardown ID [--research]\n' "$PROG" >&2
  printf '       fail-closed: dirty or unpushed keeps the lease (ship). kind:research: clean + no local commits.\n' >&2
  printf '       --research: force research gate when br labels are unavailable. Does not close the br issue.\n' >&2
}

usage_jobs() {
  printf 'usage: %s jobs add ID worker=ALIAS worktree=PATH [branch=NAME]\n' "$PROG" >&2
  printf '       %s jobs set ID [worker=ALIAS] [worktree=PATH] [branch=NAME]\n' "$PROG" >&2
  printf '       %s jobs reported ID\n' "$PROG" >&2
  printf '       %s jobs done ID\n' "$PROG" >&2
  printf '       %s jobs list [--json]\n' "$PROG" >&2
}

die_jobs_usage() {
  printf '[cmdp] error: %s\n' "$*" >&2
  usage_jobs
  exit 2
}

usage_artifact() {
  printf 'usage: %s artifact path ID\n' "$PROG" >&2
  printf '       %s artifact add ID FILE\n' "$PROG" >&2
  printf '       %s artifact get ID\n' "$PROG" >&2
}

die_artifact_usage() {
  printf '[cmdp] error: %s\n' "$*" >&2
  usage_artifact
  exit 2
}

usage_gate() {
  printf 'usage: %s gate ID [--model M]\n' "$PROG" >&2
  printf '\n' >&2
  printf 'Headless quality gate (no pane, no lease, no mail).\n' >&2
  printf 'Extracts the artifact with artifact get, reviews it against\n' >&2
  printf 'templates/gate-rubric.md, records a gate:v1 comment.\n' >&2
  printf '\n' >&2
  printf '  --model M     reviewer model (default: %s)\n' "$DEFAULT_GATE_MODEL" >&2
  printf '  CP_GATE_CMD   override reviewer command; reads prompt on stdin,\n' >&2
  printf '                writes a structured verdict on stdout\n' >&2
  printf '\n' >&2
  printf 'Stdout JSON: br_id, verdict, attempt, flags, reasons, cause;\n' >&2
  printf 'revisions when verdict=revise. cause is null on pass/revise;\n' >&2
  printf 'on escalate it is policy, operational (first unparseable — re-run\n' >&2
  printf 'gate once), or operational_persistent (prior gate was operational —\n' >&2
  printf 'swap --model or surface to the caller; do not loop).\n' >&2
  printf 'Reasons/revisions are truncated with an ellipsis if the JSON would\n' >&2
  printf 'exceed a few hundred words. Never includes the artifact body.\n' >&2
  printf '\n' >&2
  printf 'Exit: 0 pass, 10 revise, 20 escalate; other nonzero is operational.\n' >&2
  printf 'A pass does NOT close the issue or authorize implementation —\n' >&2
  printf 'the orchestrator does that.\n' >&2
}

die_gate_usage() {
  printf '[cmdp] error: %s\n' "$*" >&2
  usage_gate
  exit 2
}

usage_doctor() {
  printf 'usage: %s doctor [--json]\n' "$PROG" >&2
  printf '\n' >&2
  printf 'Read-only host and worker CLI discovery. No lease, no muxa dispatch,\n' >&2
  printf 'no jobs writes. Exit 0 when host tools are present; worker CLI gaps\n' >&2
  printf 'are reported, not a failure. Exit 2 when a host tool is missing.\n' >&2
}

die_doctor_usage() {
  printf '[cmdp] error: %s\n' "$*" >&2
  usage_doctor
  exit 2
}

die() { printf '[cmdp] error: %s\n' "$*" >&2; exit 1; }
die_usage() { printf '[cmdp] error: %s\n' "$*" >&2; usage; }
log() { printf '[cmdp] %s\n' "$*"; }

abs_git_common() {
  local d="$1" g parent
  g="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  if [[ "$g" != /* ]]; then
    g="$d/$g"
  fi
  parent="$(cd "$(dirname "$g")" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$g")"
}

normalize_path() {
  local p="$1" d b
  if [[ -d "$p" ]]; then
    (cd "$p" && pwd -P)
    return 0
  fi
  d="$(dirname "$p")"
  b="$(basename "$p")"
  if [[ -d "$d" ]]; then
    printf '%s/%s\n' "$(cd "$d" && pwd -P)" "$b"
  else
    printf '%s\n' "$p"
  fi
}

require_muxa() {
  if ! command -v muxa >/dev/null 2>&1 && [[ -z "${MUXA_WHO_CMD:-}" ]]; then
    printf '[cmdp] error: muxa not on PATH\n' >&2
    exit 2
  fi
}

assert_canonical_clone() {
  local name="$1"
  local clone="$CP_HOME/projects/$name"
  local clone_abs toplevel common gitdir home_abs

  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "invalid project name: $name (use the data/projects.md Name slug)"
  fi
  if [[ ! -d "$clone" ]]; then
    die "project clone not at $clone (command-post home $CP_HOME). Clone into projects/$name; not ~/$name."
  fi

  clone_abs="$(cd "$clone" && pwd -P)"

  if [[ -d "$HOME/$name" ]]; then
    home_abs="$(cd "$HOME/$name" && pwd -P)"
    if [[ "$clone_abs" == "$home_abs" ]]; then
      die "projects/$name resolves to ~/$name ($clone_abs). Lease only from command-post projects/<name>."
    fi
  fi

  toplevel="$(git -C "$clone_abs" rev-parse --show-toplevel 2>/dev/null)" \
    || die "not a git clone: $clone_abs"
  toplevel="$(cd "$toplevel" && pwd -P)"
  if [[ "$toplevel" != "$clone_abs" ]]; then
    die "nested wrong git: $clone_abs is inside $toplevel — need a clone at projects/$name"
  fi

  if [[ ! -d "$clone_abs/.git" ]]; then
    die "projects/$name is not a primary clone ($clone_abs/.git is not a directory; another repo's worktree?)"
  fi

  common="$(abs_git_common "$clone_abs")" \
    || die "cannot resolve git-common-dir for $clone_abs"
  gitdir="$(cd "$clone_abs/.git" && pwd -P)"
  if [[ "$common" != "$gitdir" ]]; then
    die "projects/$name git-common-dir is $common, not $gitdir. Lease only from the canonical clone."
  fi

  printf '%s\n' "$clone_abs"
}

default_base_branch() {
  local repo="$1" ref
  ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  case "$ref" in
    origin/*) printf '%s' "${ref#origin/}" ;;
    *) printf 'main' ;;
  esac
}

# git lists the main worktree first.
primary_worktree() {
  git -C "$1" worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{ sub(/^worktree /, ""); print; exit }'
}

# Git assertions that used to live in muxa preflight. Key off the canonical
# clone (not command-post cwd) so worktrees resolve against projects/<name>/.git.
check_git_preflight() {
  local clone="$1"
  shift
  local base="${BASE:-}" common primary branch arg raw wt wt_common fail=0

  common="$(abs_git_common "$clone")" || {
    printf '[cmdp] fail: repo %s has no resolvable git dir\n' "$clone" >&2
    return 1
  }

  [[ -n "$base" ]] || base="$(default_base_branch "$clone")"
  log "base branch $base"

  primary="$(primary_worktree "$clone")"
  if [[ -z "$primary" ]]; then
    printf '[cmdp] fail: primary checkout: git worktree list returned nothing\n' >&2
    fail=1
    primary=""
  elif [[ ! -d "$primary" ]]; then
    printf '[cmdp] fail: primary %s does not exist\n' "$primary" >&2
    fail=1
    primary=""
  else
    primary="$(cd "$primary" && pwd -P)"
    branch="$(git -C "$primary" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -z "$branch" ]]; then
      printf '[cmdp] fail: primary %s is detached (want %s)\n' "$primary" "$base" >&2
      fail=1
    elif [[ "$branch" == "$base" ]]; then
      log "primary $primary on $base"
    else
      printf '[cmdp] fail: primary %s on %s (want %s)\n' "$primary" "$branch" "$base" >&2
      fail=1
    fi
  fi

  for arg in "$@"; do
    if [[ "$arg" == /* ]]; then
      raw="$arg"
    else
      raw="$clone/$arg"
    fi
    if [[ ! -d "$raw" ]]; then
      printf '[cmdp] fail: worktree %s does not exist\n' "$arg" >&2
      fail=1
      continue
    fi
    wt="$(cd "$raw" && pwd -P)"
    wt_common="$(abs_git_common "$wt" || true)"
    if [[ -z "$wt_common" ]]; then
      printf '[cmdp] fail: worktree %s is not a git worktree\n' "$wt" >&2
      fail=1
    elif [[ "$wt_common" != "$common" ]]; then
      printf '[cmdp] fail: worktree %s belongs to another repo (%s)\n' "$wt" "$wt_common" >&2
      fail=1
    elif [[ -n "$primary" && "$wt" == "$primary" ]]; then
      printf '[cmdp] fail: worktree %s is the primary checkout, not a linked worktree\n' "$wt" >&2
      fail=1
    else
      branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
      log "worktree $wt linked on $branch"
    fi
  done

  [[ "$fail" -eq 0 ]]
}

# Occupancy from muxa who --json (array of {name,id,parent,kind,state,pane,
# session,cwd}; parent/session may be null). state is idle|busy|ghost
# (muxa#95; the status key is gone — do not read it). Policy lives here:
# idle|busy → promote-not-spawn; ghost → occupied cwd, do not promote
# (muxa kill NAME|ID or restart the CLI); anything else → fail closed.
# The human who table is a UI and will drift — do not scrape it.
who_json_rows() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for muxa who --json)\n' >&2
    exit 2
  fi
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    rows = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: muxa who --json: not JSON (need muxa who --json; do not scrape the human table)\n")
    sys.exit(2)
if not isinstance(rows, list):
    sys.stderr.write("[cmdp] error: muxa who --json: expected an array\n")
    sys.exit(2)
for r in rows:
    if not isinstance(r, dict):
        sys.stderr.write("[cmdp] error: muxa who --json: expected objects\n")
        sys.exit(2)
    name = r.get("name") if r.get("name") is not None else ""
    state = r.get("state") if r.get("state") is not None else ""
    cwd = r.get("cwd") if r.get("cwd") is not None else ""
    kind = r.get("kind") if r.get("kind") is not None else ""
    if str(state) == "":
        sys.stderr.write("[cmdp] error: muxa who --json: missing state\n")
        sys.exit(2)
    if "\t" in str(name) or "\n" in str(name) or "\t" in str(state) or "\n" in str(state) or "\t" in str(cwd) or "\n" in str(cwd) or "\t" in str(kind) or "\n" in str(kind):
        sys.stderr.write("[cmdp] error: muxa who --json: field contains a tab or newline\n")
        sys.exit(2)
    sys.stdout.write("%s\t%s\t%s\t%s\n" % (name, state, cwd, kind))
'
}

check_occupancy() {
  local -a targets=()
  local t line name state cwd resolved self collisions ghost_hits
  local -a who_cmd
  collisions=0
  ghost_hits=0

  for t in "$@"; do
    targets+=("$(normalize_path "$t")")
  done

  if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    who_cmd=($MUXA_WHO_CMD)
  else
    who_cmd=(muxa who --json)
  fi

  self="${MUXA_WHOAMI:-}"
  if [[ -z "$self" && -z "${MUXA_WHO_CMD:-}" ]] && command -v muxa >/dev/null 2>&1; then
    self="$(muxa whoami 2>/dev/null || true)"
  fi

  local who_out parsed
  if ! who_out="$("${who_cmd[@]}")"; then
    printf '[cmdp] error: muxa who --json failed\n' >&2
    exit 2
  fi
  if ! parsed="$(printf '%s\n' "$who_out" | who_json_rows)"; then
    exit 2
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r name state cwd _ <<< "$line"
    [[ -n "$cwd" ]] || continue
    resolved="$(normalize_path "$cwd")"

    [[ -n "$self" && "$name" == "$self" ]] && continue

    local hit=0
    for t in "${targets[@]}"; do
      if [[ "$resolved" == "$t" ]]; then
        hit=1
        break
      fi
    done
    [[ "$hit" -eq 1 ]] || continue

    case "$state" in
      idle|busy)
        printf '[cmdp] promote-not-spawn: live worker %s occupies %s\n' "$name" "$resolved" >&2
        printf '[cmdp] same worktree still held → muxa send %s (do not muxa dispatch, do not treehouse get --lease)\n' "$name" >&2
        collisions=$((collisions + 1))
        ;;
      ghost)
        printf '[cmdp] occupied cwd: ghost worker %s on %s — muxa kill NAME|ID for a dead pane, or restart the CLI in that pane; do not promote, do not dispatch\n' "$name" "$resolved" >&2
        ghost_hits=$((ghost_hits + 1))
        ;;
      *)
        printf '[cmdp] occupied cwd: worker %s (state %s) on %s — do not dispatch\n' "$name" "$state" "$resolved" >&2
        collisions=$((collisions + 1))
        ;;
    esac
  done <<< "$parsed"

  if [[ "$collisions" -gt 0 || "$ghost_hits" -gt 0 ]]; then
    return 1
  fi
  log "clear: no other live registered worker on the given worktree(s)"
}

# muxa dispatch warns on stderr when cwd is occupied; muxa who --json can omit
# that worker (muxa#121). Fail closed on the contradiction (command-post#77).
dispatch_occupancy_warning_contradiction() {
  local stderr_file="$1"
  local warned="" line name
  local -a who_cmd

  warned="$(grep -Eo 'already has live worker [^[:space:]]+' "$stderr_file" 2>/dev/null | head -n1 | sed 's/.*already has live worker //' || true)"
  [[ -n "$warned" ]] || return 0

  if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    who_cmd=($MUXA_WHO_CMD)
  else
    who_cmd=(muxa who --json)
  fi

  local who_out parsed
  if ! who_out="$("${who_cmd[@]}")"; then
    printf '[cmdp] error: muxa who --json failed while checking dispatch occupancy warning\n' >&2
    return 1
  fi
  if ! parsed="$(printf '%s\n' "$who_out" | who_json_rows)"; then
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r name _ _ _ <<< "$line"
    if [[ "$name" == "$warned" ]]; then
      return 0
    fi
  done <<< "$parsed"

  printf '[cmdp] fail: muxa dispatch warns cwd already has live worker %s but muxa who --json omits that worker\n' "$warned" >&2
  printf '[cmdp] contradicting signals — roster absence is not proof the worker is dead; inspect with muxa tail %s before proceeding\n' "$warned" >&2
  return 1
}

# muxa dispatch may succeed before we detect an occupancy contradiction (#77).
# Kill the pane it created before returning the lease — never pool a worktree
# that still has a live pane on it.
dispatch_kill_orphan_pane() {
  local dispatch_stdout="$1"
  local parsed worker

  if ! parsed="$(printf '%s\n' "$dispatch_stdout" | parse_dispatch_json 2>/dev/null)"; then
    printf '[cmdp] error: occupancy contradiction but muxa dispatch JSON is unusable — lease kept\n' >&2
    DISPATCH_KEEP_LEASE=1
    return 1
  fi
  IFS=$'\t' read -r worker _ _ <<< "$parsed"
  if [[ -z "$worker" ]]; then
    printf '[cmdp] error: occupancy contradiction but muxa dispatch JSON has no worker name — lease kept\n' >&2
    DISPATCH_KEEP_LEASE=1
    return 1
  fi
  require_muxa_bin
  if ! muxa kill "$worker"; then
    printf '[cmdp] error: occupancy contradiction — muxa kill %s failed; lease kept on worktree\n' "$worker" >&2
    DISPATCH_KEEP_LEASE=1
    return 1
  fi
  return 0
}

cmd_check() {
  local project=""
  local -a worktrees=()
  BASE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        [[ $# -ge 2 ]] || die_usage "--project needs NAME"
        project="$2"
        shift 2
        ;;
      --base)
        [[ $# -ge 2 ]] || die_usage "--base needs BRANCH"
        BASE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        ;;
      --)
        shift
        worktrees+=("$@")
        break
        ;;
      -*)
        die_usage "unknown flag $1"
        ;;
      *)
        worktrees+=("$1")
        shift
        ;;
    esac
  done

  [[ -n "$project" ]] || die_usage "missing --project NAME"
  [[ ${#worktrees[@]} -gt 0 ]] || die_usage "missing WORKTREE"

  local clone rc=0
  clone="$(assert_canonical_clone "$project")" || exit $?
  log "clone $clone"

  if ! check_git_preflight "$clone" "${worktrees[@]}"; then
    rc=1
  fi

  require_muxa
  if [[ "$rc" -eq 0 ]]; then
    if ! check_occupancy "${worktrees[@]}"; then
      rc=1
    fi
  fi
  [[ "$rc" -eq 0 ]] || exit 1
  log "ok"
}

usage_lease() {
  printf 'usage: %s lease --project NAME\n' "$PROG" >&2
  printf '\n' >&2
  printf 'Lease a worktree from the canonical clone at projects/<name>.\n' >&2
  printf 'Runs treehouse get --lease with cwd in that clone (treehouse keys\n' >&2
  printf 'off cwd, not a path argument). Prints the absolute worktree path\n' >&2
  printf 'on stdout only. Follow with bin/cmdp check --project NAME "$worktree".\n' >&2
}

cmd_lease() {
  local project=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        [[ $# -ge 2 ]] || die_usage "--project needs NAME"
        project="$2"
        shift 2
        ;;
      -h|--help)
        usage_lease
        ;;
      *)
        die_usage "unexpected arg $1"
        ;;
    esac
  done
  [[ -n "$project" ]] || die_usage "missing --project NAME"

  local clone wt
  clone="$(assert_canonical_clone "$project")" || exit $?
  wt="$(treehouse_get_lease "$clone")"
  printf '%s\n' "$wt"
}

jobs_file() {
  printf '%s\n' "${CP_JOBS_FILE:-$CP_HOME/state/jobs.tsv}"
}

jobs_ensure() {
  local f
  f="$(jobs_file)"
  mkdir -p "$(dirname "$f")"
  if [[ ! -f "$f" ]]; then
    printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$f"
  fi
}

jobs_dispatched_at_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

jobs_emit_row() {
  local job="$1" worker="$2" worktree="$3" branch="$4"
  local dispatched_at="${5:-}" reported_at="${6:-}" origin="${7:-}"
  if [[ -n "$origin" ]]; then
    if [[ -n "$reported_at" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at" "$origin"
    elif [[ -n "$dispatched_at" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t\t%s\n' "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$origin"
    else
      printf '%s\t%s\t%s\t%s\t\t\t%s\n' "$job" "$worker" "$worktree" "$branch" "$origin"
    fi
  elif [[ -n "$reported_at" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at"
  elif [[ -n "$dispatched_at" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$job" "$worker" "$worktree" "$branch" "$dispatched_at"
  else
    printf '%s\t%s\t%s\t%s\n' "$job" "$worker" "$worktree" "$branch"
  fi
}

# Parse one jobs.tsv data row. Tab is IFS whitespace in bash, so IFS=$'\t' read
# collapses consecutive tabs and drops empty middle fields (#85).
jobs_parse_row() {
  local line="$1" parsed
  parsed="$(printf '%s\n' "$line" | awk -F'\t' '{
    for (i = 1; i <= 7; i++) {
      if (i > 1) printf "\036"
      printf "%s", (i <= NF ? $i : "")
    }
    printf "\n"
  }')"
  IFS=$'\036' read -r job worker worktree branch dispatched_at reported_at origin <<< "$parsed"
}

# Heal rows corrupted by the old IFS read: origin shifted into reported_at.
jobs_heal_row_fields() {
  if [[ -n "$reported_at" && -z "$origin" ]]; then
    if ! [[ "$reported_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      origin="$reported_at"
      reported_at=""
    fi
  fi
}

validate_job_id() {
  local id="$1"
  if [[ ! "$id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "invalid job id: $id (br id; no whitespace)"
  fi
}

require_no_ctl() {
  local key="$1" val="$2"
  case "$val" in
    *$'\t'*|*$'\n'*) die "invalid $key: tabs and newlines are not allowed" ;;
  esac
  [[ -n "$val" ]] || die "empty $key="
}

# Home tracker only. --db (realpath) so br never auto-inits a rogue
# .beads from a leased worktree cwd. BR_DB is a test override.
resolve_beads_db() {
  local raw dir db
  if [[ -n "${BR_DB:-}" ]]; then
    raw="$BR_DB"
    if [[ -d "$raw" ]]; then
      db="$raw/beads.db"
      [[ -f "$db" ]] || die "BR_DB is a directory but has no beads.db: $raw"
    elif [[ -f "$raw" ]]; then
      db="$raw"
    else
      die "BR_DB is not a beads database: $raw"
    fi
    normalize_path "$db"
    return 0
  fi
  dir="$CP_HOME/.beads"
  if [[ ! -d "$dir" ]]; then
    die "no .beads at $CP_HOME — br must run against the command-post home tracker (refusing to init a second database)"
  fi
  db="$dir/beads.db"
  if [[ ! -f "$db" ]]; then
    die "no beads.db in $dir"
  fi
  normalize_path "$db"
}

require_br() {
  if ! command -v br >/dev/null 2>&1; then
    printf '[cmdp] error: br not on PATH\n' >&2
    exit 2
  fi
}

br_show_argv() {
  BR_SHOW_ARGV=()
  if [[ -n "${BR_SHOW_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    BR_SHOW_ARGV=($BR_SHOW_CMD)
  else
    require_br
    BR_SHOW_ARGV=(br --db "$(resolve_beads_db)" show --json)
  fi
}

require_br_issue() {
  local id="$1"
  br_show_argv
  # br discovers .beads/ from cwd. Orchestrator home is CP_HOME; --db
  # pins the tracker so a worktree cwd cannot spawn a second database.
  if ! (cd "$CP_HOME" && "${BR_SHOW_ARGV[@]}" "$id" >/dev/null); then
    die "no br issue $id — jobs are keyed by br id; create the issue first"
  fi
}

br_issue_label_value() {
  local id="$1" prefix="$2"
  local raw val
  br_show_argv
  if ! raw="$(cd "$CP_HOME" && "${BR_SHOW_ARGV[@]}" "$id" 2>/dev/null)"; then
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    return 1
  fi
  if val="$(BR_LABEL_PREFIX="$prefix" python3 -c '
import json, os, sys
raw = sys.stdin.read()
prefix = os.environ.get("BR_LABEL_PREFIX", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
if isinstance(data, list):
    data = data[0] if data else {}
labels = data.get("labels") or []
for lab in labels:
    if isinstance(lab, str) and lab.startswith(prefix):
        print(lab[len(prefix):])
        sys.exit(0)
sys.exit(1)
' <<< "$raw")"; then
    printf '%s\n' "$val"
    return 0
  fi
  return 1
}

parse_runtime_kv() {
  parsed_worker=""
  parsed_worktree=""
  parsed_branch=""
  parsed_origin=""
  local arg key val
  for arg in "$@"; do
    case "$arg" in
      *=*)
        key="${arg%%=*}"
        val="${arg#*=}"
        ;;
      *)
        die_jobs_usage "expected key=value, got $arg"
        ;;
    esac
    case "$key" in
      worker|worktree|branch|origin)
        require_no_ctl "$key" "$val"
        ;;
    esac
    case "$key" in
      worker) parsed_worker="$val" ;;
      worktree) parsed_worktree="$val" ;;
      branch) parsed_branch="$val" ;;
      origin) parsed_origin="$val" ;;
      kind|delivery|status|pr|note)
        die "refusing $key= — kind, delivery, status, PR URL, and note live on the br issue"
        ;;
      *)
        die_jobs_usage "unknown field $key= (want: worker, worktree, branch, origin)"
        ;;
    esac
  done
}

jobs_has() {
  local id="$1" f line job
  f="$(jobs_file)"
  [[ -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    job="${line%%$'\t'*}"
    if [[ "$job" == "$id" ]]; then
      return 0
    fi
  done < "$f"
  return 1
}

jobs_lookup() {
  local id="$1" f line job
  f="$(jobs_file)"
  [[ -f "$f" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    job="${line%%$'\t'*}"
    if [[ "$job" == "$id" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  done < "$f"
  return 1
}

jobs_rewrite() {
  local f tmp line job worker worktree branch dispatched_at reported_at origin
  local target="$1" action="$2"
  local new_worker="$3" new_worktree="$4" new_branch="$5"
  local found=0
  f="$(jobs_file)"
  tmp="$(mktemp "${f}.XXXXXX")"
  printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$tmp"
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      [[ "$line" == \#* ]] && continue
      jobs_parse_row "$line"
      jobs_heal_row_fields
      if [[ "$job" != "$target" ]]; then
        jobs_emit_row "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at" "$origin" >> "$tmp"
        continue
      fi
      found=1
      if [[ "$action" == "drop" ]]; then
        continue
      fi
      [[ -n "$new_worker" ]] && worker="$new_worker"
      [[ -n "$new_worktree" ]] && worktree="$new_worktree"
      [[ -n "$new_branch" ]] && branch="$new_branch"
      jobs_emit_row "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at" "$origin" >> "$tmp"
    done < "$f"
  fi
  if [[ "$found" -eq 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$f"
}

jobs_stamp_reported() {
  local target="$1" f tmp line job worker worktree branch dispatched_at reported_at origin
  local found=0 stamp effective_reported_at=""
  stamp="$(jobs_dispatched_at_now)"
  f="$(jobs_file)"
  tmp="$(mktemp "${f}.XXXXXX")"
  printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$tmp"
  if [[ -f "$f" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      [[ "$line" == \#* ]] && continue
      jobs_parse_row "$line"
      jobs_heal_row_fields
      if [[ "$job" != "$target" ]]; then
        jobs_emit_row "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at" "$origin" >> "$tmp"
        continue
      fi
      found=1
      if [[ -z "$reported_at" ]]; then
        reported_at="$stamp"
      fi
      effective_reported_at="$reported_at"
      jobs_emit_row "$job" "$worker" "$worktree" "$branch" "$dispatched_at" "$reported_at" "$origin" >> "$tmp"
    done < "$f"
  fi
  if [[ "$found" -eq 0 ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$f"
  log "jobs reported $target reported_at=$effective_reported_at"
}

resolve_worktree() {
  local p="$1"
  [[ -d "$p" ]] || die "worktree is not a directory: $p"
  normalize_path "$p"
}

resolve_branch() {
  local worktree="$1" branch="$2" detected=""
  if [[ -n "$branch" ]]; then
    printf '%s\n' "$branch"
    return 0
  fi
  # symbolic-ref works on a named branch even before the first commit;
  # rev-parse --abbrev-ref HEAD does not. Detached HEAD has no name —
  # the caller must pass branch=.
  detected="$(git -C "$worktree" symbolic-ref --short HEAD 2>/dev/null || true)"
  if [[ -z "$detected" ]]; then
    detected="$(git -C "$worktree" branch --show-current 2>/dev/null || true)"
  fi
  [[ -n "$detected" ]] || die "cannot read branch from $worktree (pass branch=NAME)"
  printf '%s\n' "$detected"
}

jobs_add() {
  local id
  [[ $# -ge 1 ]] || die_jobs_usage "add needs ID"
  id="$1"
  shift
  validate_job_id "$id"
  parse_runtime_kv "$@"
  [[ -n "$parsed_worker" ]] || die_jobs_usage "add needs worker=ALIAS"
  [[ -n "$parsed_worktree" ]] || die_jobs_usage "add needs worktree=PATH"
  require_br_issue "$id"
  parsed_worktree="$(resolve_worktree "$parsed_worktree")"
  parsed_branch="$(resolve_branch "$parsed_worktree" "$parsed_branch")"
  jobs_ensure
  if jobs_has "$id"; then
    die "job $id already mapped — use set to change worker/worktree/branch"
  fi
  local dispatched_at
  dispatched_at="$(jobs_dispatched_at_now)"
  jobs_emit_row "$id" "$parsed_worker" "$parsed_worktree" "$parsed_branch" "$dispatched_at" "" "$parsed_origin" >> "$(jobs_file)"
  log "jobs add $id worker=$parsed_worker branch=$parsed_branch worktree=$parsed_worktree dispatched_at=$dispatched_at origin=${parsed_origin:-}"
}

jobs_set() {
  local id row job worker worktree branch
  [[ $# -ge 1 ]] || die_jobs_usage "set needs ID"
  id="$1"
  shift
  validate_job_id "$id"
  [[ $# -gt 0 ]] || die_jobs_usage "set needs at least one of worker=, worktree=, branch="
  parse_runtime_kv "$@"
  if [[ -n "$parsed_worktree" ]]; then
    parsed_worktree="$(resolve_worktree "$parsed_worktree")"
    if [[ -z "$parsed_branch" ]]; then
      parsed_branch="$(resolve_branch "$parsed_worktree" "")"
    fi
  fi
  jobs_ensure
  if ! jobs_rewrite "$id" set "$parsed_worker" "$parsed_worktree" "$parsed_branch"; then
    die "no runtime row for $id — add it first"
  fi
  row="$(jobs_lookup "$id")"
  IFS=$'\t' read -r job worker worktree branch _ <<< "$row"
  log "jobs set $job worker=$worker branch=$branch worktree=$worktree"
}

jobs_reported() {
  local id arg
  [[ $# -ge 1 ]] || die_jobs_usage "reported needs ID"
  id="$1"
  shift
  validate_job_id "$id"
  for arg in "$@"; do
    case "$arg" in
      pr=*|kind=*|delivery=*|status=*|note=*)
        die "refusing ${arg%%=*}= — reported only stamps runtime state on the jobs row"
        ;;
      *)
        die_jobs_usage "reported takes ID only, got $arg"
        ;;
    esac
  done
  jobs_ensure
  if ! jobs_stamp_reported "$id"; then
    die "no runtime row for $id"
  fi
}

jobs_done() {
  local id arg
  [[ $# -ge 1 ]] || die_jobs_usage "done needs ID"
  id="$1"
  shift
  validate_job_id "$id"
  for arg in "$@"; do
    case "$arg" in
      pr=*|kind=*|delivery=*|status=*|note=*)
        die "refusing ${arg%%=*}= — put the PR URL on br close; jobs done only drops the runtime row"
        ;;
      *)
        die_jobs_usage "done takes ID only, got $arg"
        ;;
    esac
  done
  jobs_ensure
  if ! jobs_rewrite "$id" drop "" "" ""; then
    die "no runtime row for $id"
  fi
  log "jobs done $id"
}

jobs_list_json() {
  local f line job worker worktree branch
  f="$(jobs_file)"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for --json)\n' >&2
    exit 2
  fi
  {
    if [[ -f "$f" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        [[ "$line" == \#* ]] && continue
        printf '%s\n' "$line"
      done < "$f"
    fi
  } | python3 -c '
import json, sys
rows = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    job = parts[0] if len(parts) > 0 else ""
    worker = parts[1] if len(parts) > 1 else ""
    worktree = parts[2] if len(parts) > 2 else ""
    branch = parts[3] if len(parts) > 3 else ""
    row = {"job": job, "worker": worker, "worktree": worktree, "branch": branch}
    if len(parts) > 4 and parts[4]:
        row["dispatched_at"] = parts[4]
    if len(parts) > 5 and parts[5]:
        row["reported_at"] = parts[5]
    if len(parts) > 6 and parts[6]:
        row["origin"] = parts[6]
    rows.append(row)
json.dump(rows, sys.stdout)
print()
'
}

jobs_list() {
  local json=0 arg f line job worker worktree branch
  for arg in "$@"; do
    case "$arg" in
      --json) json=1 ;;
      -h|--help) usage_jobs; exit 2 ;;
      *) die_jobs_usage "unknown list flag $arg" ;;
    esac
  done
  if [[ "$json" -eq 1 ]]; then
    jobs_list_json
    return 0
  fi
  printf '%-28s %-20s %-28s %s\n' "JOB" "WORKER" "BRANCH" "WORKTREE"
  f="$(jobs_file)"
  [[ -f "$f" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" == \#* ]] && continue
    IFS=$'\t' read -r job worker worktree branch _ <<< "$line"
    printf '%-28s %-20s %-28s %s\n' "$job" "$worker" "$branch" "$worktree"
  done < "$f"
}

artifact_dir() {
  local id="$1"
  printf '%s\n' "$CP_HOME/state/artifacts/$id"
}

artifact_report() {
  local id="$1"
  printf '%s\n' "$(artifact_dir "$id")/report.md"
}

artifact_path() {
  local id dir report
  [[ $# -ge 1 ]] || die_artifact_usage "path needs ID"
  [[ $# -eq 1 ]] || die_artifact_usage "path takes ID only"
  id="$1"
  validate_job_id "$id"
  dir="$(artifact_dir "$id")"
  report="$(artifact_report "$id")"
  mkdir -p "$dir"
  printf '%s\n' "$report"
}

artifact_add() {
  local id file db tmp bytes
  [[ $# -ge 2 ]] || die_artifact_usage "add needs ID FILE"
  [[ $# -eq 2 ]] || die_artifact_usage "add takes ID FILE only"
  id="$1"
  file="$2"
  validate_job_id "$id"
  [[ -f "$file" ]] || die "not a file: $file"
  require_br
  require_br_issue "$id"
  db="$(resolve_beads_db)"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for artifact add JSON)\n' >&2
    exit 2
  fi
  bytes="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$file")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cp-artifact.XXXXXX")"
  {
    printf 'artifact:v1\n'
    cat -- "$file"
  } > "$tmp"
  # -q: br comments add --json reprints the body; never print it.
  if ! br --db "$db" comments add "$id" --file "$tmp" -q >/dev/null; then
    rm -f "$tmp"
    die "br comments add failed for $id"
  fi
  rm -f "$tmp"
  python3 -c 'import json,sys; json.dump({"br_id": sys.argv[1], "bytes": int(sys.argv[2])}, sys.stdout); print()' "$id" "$bytes"
}

# Refuse teardown when the artifact dir holds files artifact add did not mirror.
artifact_teardown_guard() {
  local id="$1" art extras=() entry
  art="$(artifact_dir "$id")"
  [[ -d "$art" ]] || return 0
  while IFS= read -r -d '' entry; do
    [[ "$entry" == "$art/report.md" ]] && continue
    extras+=("$entry")
  done < <(find "$art" -mindepth 1 -print0 2>/dev/null)
  if [[ ${#extras[@]} -eq 0 ]]; then
    return 0
  fi
  printf '[cmdp] fail: artifact dir has unmirrored files — keep the lease; mirror with artifact add or copy out before teardown:\n' >&2
  for entry in "${extras[@]}"; do
    printf '  %s\n' "$entry" >&2
  done
  exit 1
}

artifact_teardown_clean() {
  local id="$1" art
  art="$(artifact_dir "$id")"
  if [[ -n "$art" && "$art" == "$CP_HOME/state/artifacts/$id" && -d "$art" ]]; then
    rm -rf "$art"
  fi
}

artifact_get() {
  local id db raw
  [[ $# -ge 1 ]] || die_artifact_usage "get needs ID"
  [[ $# -eq 1 ]] || die_artifact_usage "get takes ID only"
  id="$1"
  validate_job_id "$id"
  require_br
  db="$(resolve_beads_db)"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for artifact get)\n' >&2
    exit 2
  fi
  if ! raw="$(br --db "$db" comments list "$id" --json)"; then
    die "cannot list comments for $id"
  fi
  br_json_stdout_check "$raw" "br comments list --json" || exit 2
  ARTIFACT_ID="$id" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    comments = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: br comments list --json: not JSON\n")
    sys.exit(2)
if isinstance(comments, dict) and "error" in comments:
    err = comments.get("error")
    if isinstance(err, dict):
        code = err.get("code") or "BR_ERROR"
        msg = err.get("message") or code
    else:
        code = "BR_ERROR"
        msg = str(err)
    sys.stderr.write("[cmdp] error: br comments list --json: %s: %s\n" % (code, msg))
    sys.exit(2)
if not isinstance(comments, list):
    sys.stderr.write("[cmdp] error: br comments list --json: expected an array\n")
    sys.exit(2)
best = None
for c in comments:
    if not isinstance(c, dict):
        continue
    text = c.get("text") if c.get("text") is not None else ""
    if not isinstance(text, str):
        continue
    first = text.splitlines()[0] if text else ""
    if first != "artifact:v1":
        continue
    created = c.get("created_at") if c.get("created_at") is not None else ""
    cid = c.get("id")
    try:
        cid_n = int(cid)
    except (TypeError, ValueError):
        cid_n = 0
    key = (str(created), cid_n)
    if best is None or key >= best[0]:
        best = (key, text)
if best is None:
    sys.stderr.write("[cmdp] error: no artifact:v1 comment on %s\n" % os.environ.get("ARTIFACT_ID", ""))
    sys.exit(1)
text = best[1]
if text.startswith("artifact:v1\r\n"):
    body = text[len("artifact:v1\r\n"):]
elif text.startswith("artifact:v1\n"):
    body = text[len("artifact:v1\n"):]
elif text == "artifact:v1":
    body = ""
else:
    body = text.split("\n", 1)[1] if "\n" in text else ""
sys.stdout.write(body)
' <<< "$raw"
}

cmd_artifact() {
  [[ $# -gt 0 ]] || die_artifact_usage "missing path|add|get"
  case "$1" in
    path)
      shift
      artifact_path "$@"
      ;;
    add)
      shift
      artifact_add "$@"
      ;;
    get)
      shift
      artifact_get "$@"
      ;;
    -h|--help)
      usage_artifact
      exit 2
      ;;
    *)
      die_artifact_usage "unknown artifact command $1 (want: path, add, get)"
      ;;
  esac
}

# Prior gate:v1 comments → attempt number and whether a revise already exists.
# Uses comments list, never br show (show inlines full bodies).
gate_prior_state() {
  local id="$1" db raw
  db="$(resolve_beads_db)"
  if ! raw="$(br --db "$db" comments list "$id" --json)"; then
    return 1
  fi
  br_json_stdout_check "$raw" "br comments list --json" || return 2
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
try:
    comments = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: br comments list --json: not JSON\n")
    sys.exit(2)
if isinstance(comments, dict) and "error" in comments:
    err = comments.get("error")
    if isinstance(err, dict):
        code = err.get("code") or "BR_ERROR"
        msg = err.get("message") or code
    else:
        code = "BR_ERROR"
        msg = str(err)
    sys.stderr.write("[cmdp] error: br comments list --json: %s: %s\n" % (code, msg))
    sys.exit(2)
if not isinstance(comments, list):
    sys.stderr.write("[cmdp] error: br comments list --json: expected an array\n")
    sys.exit(2)
n = 0
prior_revise = 0
prior_operational = 0
last_gate_text = None
verdict_re = re.compile(r"(?i)^\s*verdict\s*:\s*revise\s*$")
operational_cause_re = re.compile(r"(?i)^\s*cause\s*:\s*operational\s*$")
unparseable_re = re.compile(r"reviewer output unparseable after one retry", re.I)
for c in comments:
    if not isinstance(c, dict):
        continue
    text = c.get("text") if c.get("text") is not None else ""
    if not isinstance(text, str) or not text:
        continue
    first = text.splitlines()[0]
    if first != "gate:v1":
        continue
    n += 1
    last_gate_text = text
    for line in text.splitlines():
        if verdict_re.match(line):
            prior_revise = 1
            break
if last_gate_text:
    for line in last_gate_text.splitlines():
        if operational_cause_re.match(line):
            prior_operational = 1
            break
    if not prior_operational and unparseable_re.search(last_gate_text):
        prior_operational = 1
sys.stdout.write("%d\t%d\t%d\n" % (n + 1, prior_revise, prior_operational))
' <<< "$raw"
}

# Parse reviewer stdout into JSON. Exit 2 if unparseable.
# Tolerance: surrounding prose; last valid field wins; case-insensitive
# verdict/yes|no; optional **bold**; CRLF; trailing commentary on flag
# lines. Template echoes like "pass|revise|escalate" or "yes|no" are rejected.
parse_gate_verdict() {
  python3 -c '
import json, re, sys

text = sys.stdin.read().replace("\r\n", "\n")
if not text.strip():
    sys.exit(2)

header_re = re.compile(
    r"(?i)^\s*(?:\*\*)?(verdict|reasons|flags|revisions|destructive_scope|scope_growth|blocking_unknowns)(?:\*\*)?\s*:\s*(.*)$"
)

def token(rest):
    rest = rest.strip().strip("*").strip()
    if not rest:
        return ""
    t = rest.split()[0].lower().rstrip(",;")
    return t.strip("*")

verdict = None
flags = {}
reasons = []
revisions = []
section = None

for raw_line in text.splitlines():
    line = raw_line.strip()
    if line.startswith("```"):
        continue
    m = header_re.match(raw_line)
    if m:
        key = m.group(1).lower()
        rest = m.group(2)
        if key == "verdict":
            v = token(rest)
            if v in ("pass", "revise", "escalate"):
                verdict = v
            section = None
            continue
        if key in ("destructive_scope", "scope_growth", "blocking_unknowns"):
            v = token(rest)
            if v in ("yes", "no"):
                flags[key] = v
            section = None
            continue
        if key in ("reasons", "flags", "revisions"):
            section = key
            continue
    if section in ("reasons", "revisions"):
        bullet = raw_line.strip()
        if bullet.startswith(("-", "*")):
            item = bullet[1:].strip()
            if item:
                (reasons if section == "reasons" else revisions).append(item)

need = ("destructive_scope", "scope_growth", "blocking_unknowns")
if verdict is None or any(k not in flags for k in need):
    sys.exit(2)

json.dump({
    "verdict": verdict,
    "reasons": reasons,
    "flags": {k: flags[k] for k in need},
    "revisions": revisions,
}, sys.stdout)
print()
'
}

run_gate_reviewer() {
  local prompt_file="$1" model="$2" out_file="$3"
  if [[ -n "${CP_GATE_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    local -a cmd=($CP_GATE_CMD)
    "${cmd[@]}" < "$prompt_file" > "$out_file"
    return $?
  fi
  local -a gate_argv=()
  local gate_source=""
  resolve_role_argv gate-reviewer gate_argv gate_source
  require_worker_cmd "${gate_argv[0]}" gate-reviewer "$gate_source"
  local bin="${gate_argv[0]}"
  if [[ "$bin" == agent || "$bin" == cursor-agent ]]; then
    # Headless cursor agent: --print is non-interactive; --mode ask is
    # read-only (the rubric forbids repo access); text so we parse prose.
    # Prompt is the positional argument — the CLI does not document stdin
    # as the prompt. Do not pass --trust / --yolo / --workspace.
    agent --print --mode ask --output-format text --model "$model" -- "$(cat "$prompt_file")" > "$out_file"
    return $?
  fi
  printf '[cmdp] error: gate-reviewer CLI %q is not supported for headless gate (set CP_GATE_CMD to override)\n' "$bin" >&2
  exit 2
}

apply_gate_policy() {
  python3 -c '
import json, os, sys

d = json.load(sys.stdin)
verdict = d.get("verdict")
flags = d.get("flags") or {}
reasons = [str(x) for x in (d.get("reasons") or [])]
revisions = [str(x) for x in (d.get("revisions") or [])]
escalate_cause = d.get("cause") if d.get("cause") in ("operational", "operational_persistent") else None
need = ("destructive_scope", "scope_growth", "blocking_unknowns")
norm = {}
for k in need:
    v = str(flags.get(k, "no")).lower()
    norm[k] = v if v in ("yes", "no") else "no"

forced = [k for k in need if norm[k] == "yes"]
if forced:
    verdict = "escalate"
    escalate_cause = "policy"
    note = "flag forced escalate: " + ", ".join(forced)
    if note not in reasons:
        reasons.append(note)

if os.environ.get("GATE_PRIOR_REVISE") == "1" and verdict == "revise":
    verdict = "escalate"
    escalate_cause = "policy"
    note = "attempt cap: a prior revise already exists (one revision max)"
    if note not in reasons:
        reasons.append(note)

if verdict == "escalate" and escalate_cause is None:
    escalate_cause = "policy"

cause = escalate_cause if verdict == "escalate" else None

attempt = int(os.environ["GATE_ATTEMPT"])
br_id = os.environ["GATE_ID"]

def short_items(items):
    out = []
    for r in items:
        one = " ".join(str(r).split())
        if one:
            out.append(one)
    return out

def bullets(items):
    return ["- " + x for x in short_items(items)]

lines = [
    "gate:v1",
    "attempt: %d" % attempt,
    "verdict: %s" % verdict,
]
if verdict == "escalate" and cause:
    lines.append("cause: %s" % cause)
lines.extend([
    "flags:",
    "destructive_scope: %s" % norm["destructive_scope"],
    "scope_growth: %s" % norm["scope_growth"],
    "blocking_unknowns: %s" % norm["blocking_unknowns"],
    "reasons:",
])
lines.extend(bullets(reasons))
if verdict == "revise":
    lines.append("revisions:")
    lines.extend(bullets(revisions))

with open(os.environ["GATE_COMMENT"], "w") as f:
    f.write("\n".join(lines) + "\n")

# Parent may read this JSON (verdicts are short). Cap so a bloated
# reviewer cannot dump a wall of text — never the artifact body.
JSON_WORD_CAP = 300

def payload(rs, rvs):
    o = {
        "br_id": br_id,
        "verdict": verdict,
        "attempt": attempt,
        "flags": norm,
        "reasons": rs,
        "cause": cause,
    }
    if verdict == "revise":
        o["revisions"] = rvs
    return o

def wc(rs, rvs):
    return len(json.dumps(payload(rs, rvs)).split())

def fit(items, measure):
    if measure(items) <= JSON_WORD_CAP:
        return list(items)
    kept = []
    for item in items:
        if measure(kept + [item]) <= JSON_WORD_CAP:
            kept.append(item)
            continue
        words = item.split()
        chosen = None
        for n in range(len(words), -1, -1):
            trial = " ".join(words[:n] + ["..."]) if n else "..."
            if measure(kept + [trial]) <= JSON_WORD_CAP:
                chosen = trial
                break
        if chosen is not None:
            kept.append(chosen)
        elif not kept:
            kept = ["..."]
        elif not kept[-1].endswith("..."):
            if measure(kept + ["..."]) <= JSON_WORD_CAP:
                kept.append("...")
            else:
                lw = kept[-1].split()
                for n in range(len(lw), -1, -1):
                    trial = " ".join(lw[:n] + ["..."]) if n else "..."
                    if measure(kept[:-1] + [trial]) <= JSON_WORD_CAP:
                        kept[-1] = trial
                        break
        break
    return kept

rs = short_items(reasons)
rvs = short_items(revisions) if verdict == "revise" else []
if wc(rs, rvs) > JSON_WORD_CAP:
    rs = fit(rs, lambda trial: wc(trial, []))
    if verdict == "revise":
        rvs = fit(rvs, lambda trial: wc(rs, trial))

with open(os.environ["GATE_JSON"], "w") as f:
    json.dump(payload(rs, rvs), f)
    f.write("\n")
sys.stdout.write(verdict + "\n")
'
}

cmd_gate() {
  local id="" model="$DEFAULT_GATE_MODEL"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --model)
        [[ $# -ge 2 ]] || die_gate_usage "--model needs M"
        model="$2"
        shift 2
        ;;
      -h|--help)
        usage_gate
        exit 2
        ;;
      --)
        shift
        ;;
      -*)
        die_gate_usage "unknown flag $1"
        ;;
      *)
        if [[ -n "$id" ]]; then
          die_gate_usage "gate takes one ID"
        fi
        id="$1"
        shift
        ;;
    esac
  done
  [[ -n "$id" ]] || die_gate_usage "gate needs ID"
  validate_job_id "$id"
  require_no_ctl model "$model"
  require_br
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for gate)\n' >&2
    exit 2
  fi

  local rubric="$ROOT/templates/gate-rubric.md"
  [[ -f "$rubric" ]] || die "missing gate rubric: $rubric"

  local tmpd
  tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cp-gate.XXXXXX")"
  trap "rm -rf \"$tmpd\"" EXIT

  # artifact get is the only sanctioned reader (not br show).
  if ! artifact_get "$id" >"$tmpd/artifact.md" 2>"$tmpd/get.err"; then
    if grep -q 'no artifact:v1 comment' "$tmpd/get.err"; then
      printf '[cmdp] error: no artifact on %s — cannot gate\n' "$id" >&2
      exit 1
    fi
    cat "$tmpd/get.err" >&2
    die "cannot extract artifact for $id"
  fi

  {
    cat "$rubric"
    printf '\n'
    cat "$tmpd/artifact.md"
  } > "$tmpd/prompt"

  local state attempt prior_revise prior_operational
  state="$(gate_prior_state "$id")" || die "cannot list comments for $id"
  IFS=$'\t' read -r attempt prior_revise prior_operational <<< "$state"
  [[ -n "$attempt" ]] || die "cannot parse gate history for $id"

  local parsed=""
  if ! run_gate_reviewer "$tmpd/prompt" "$model" "$tmpd/out1"; then
    : # nonempty/empty output still goes through the parser
  fi
  if ! parsed="$(parse_gate_verdict < "$tmpd/out1")"; then
    if ! run_gate_reviewer "$tmpd/prompt" "$model" "$tmpd/out2"; then
      :
    fi
    if ! parsed="$(parse_gate_verdict < "$tmpd/out2")"; then
      if [[ "$prior_operational" == "1" ]]; then
        parsed='{"verdict":"escalate","cause":"operational_persistent","reasons":["reviewer model cannot meet parse contract (prior operational escalate)"],"flags":{"destructive_scope":"no","scope_growth":"no","blocking_unknowns":"no"},"revisions":[]}'
      else
        parsed='{"verdict":"escalate","cause":"operational","reasons":["reviewer output unparseable after one retry"],"flags":{"destructive_scope":"no","scope_growth":"no","blocking_unknowns":"no"},"revisions":[]}'
      fi
    fi
  fi

  local verdict db
  if ! verdict="$(
    GATE_ID="$id" GATE_ATTEMPT="$attempt" GATE_PRIOR_REVISE="$prior_revise" \
      GATE_COMMENT="$tmpd/comment" GATE_JSON="$tmpd/result.json" \
      apply_gate_policy <<< "$parsed"
  )"; then
    die "cannot apply gate policy for $id"
  fi

  db="$(resolve_beads_db)"
  if ! br --db "$db" comments add "$id" --file "$tmpd/comment" -q >/dev/null; then
    die "br comments add failed for $id"
  fi
  cat "$tmpd/result.json"
  case "$verdict" in
    pass) exit 0 ;;
    revise) exit 10 ;;
    escalate) exit 20 ;;
    *) die "internal: bad verdict $verdict" ;;
  esac
}

cmd_jobs() {
  [[ $# -gt 0 ]] || die_jobs_usage "missing add|set|reported|done|list"
  case "$1" in
    add)
      shift
      jobs_add "$@"
      ;;
    set)
      shift
      jobs_set "$@"
      ;;
    reported)
      shift
      jobs_reported "$@"
      ;;
    done)
      shift
      jobs_done "$@"
      ;;
    list)
      shift
      jobs_list "$@"
      ;;
    -h|--help)
      usage_jobs
      exit 2
      ;;
    *)
      die_jobs_usage "unknown jobs command $1 (want: add, set, reported, done, list)"
      ;;
  esac
}

# status: read-only fleet snapshot. Composes muxa who --json, muxa broker status,
# state/jobs.tsv (via jobs_list_json), and br list --json (never br show — that
# inlines comment bodies). No daemon, no new persistence, no tmux; --serve is an
# opt-in foreground listener. See status_assemble for the phase/glyph matrix
# and the join precedence (jobs.worker -> jobs.worktree -> branch==br-id).
status_who_json() {
  local -a who_cmd
  if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    who_cmd=($MUXA_WHO_CMD)
  else
    require_muxa_bin
    who_cmd=(muxa who --json)
  fi
  local out
  if ! out="$("${who_cmd[@]}")"; then
    die "muxa who --json failed"
  fi
  printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    rows = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: muxa who --json: not JSON\n")
    sys.exit(2)
if not isinstance(rows, list):
    sys.stderr.write("[cmdp] error: muxa who --json: expected an array\n")
    sys.exit(2)
out = []
for r in rows:
    if not isinstance(r, dict):
        sys.stderr.write("[cmdp] error: muxa who --json: expected objects\n")
        sys.exit(2)
    name = r.get("name")
    state = r.get("state")
    if not name or not state:
        sys.stderr.write("[cmdp] error: muxa who --json: missing name or state\n")
        sys.exit(2)
    out.append({
        "name": str(name),
        "id": r.get("id"),
        "parent": r.get("parent"),
        "kind": r.get("kind"),
        "state": str(state),
        "pane": r.get("pane"),
        "session": r.get("session"),
        "cwd": r.get("cwd"),
    })
json.dump(out, sys.stdout)
'
}

# Broker degrades gracefully: a failed call or unparseable output becomes
# {"ok": false} — nodes are still emitted (never abort the snapshot for a
# down broker). Exactly one invocation per snapshot.
status_broker_json() {
  local -a broker_cmd
  if [[ -n "${MUXA_BROKER_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    broker_cmd=($MUXA_BROKER_CMD)
  else
    broker_cmd=(muxa broker status)
  fi
  local out rc=0
  out="$("${broker_cmd[@]}" 2>/dev/null)" || rc=$?
  if [[ "$rc" -ne 0 || -z "$out" ]]; then
    printf '{"ok": false}'
    return 0
  fi
  printf '%s' "$out" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    d = None
if not isinstance(d, dict):
    json.dump({"ok": False}, sys.stdout)
else:
    if "ok" not in d:
        d["ok"] = True
    json.dump(d, sys.stdout)
'
}

# BR_LIST_CMD replaces the "br --db $db" prefix only (mirrors BR_SHOW_CMD);
# the real, varying subcommand+flags are appended at each call site, so one
# override serves both the broad open/in_progress list and the targeted
# `-s closed` lookup — a test stub dispatches on the trailing args it sees.
status_br_prefix() {
  if [[ -n "${BR_LIST_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    BR_PREFIX=($BR_LIST_CMD)
  else
    require_br
    local db
    db="$(resolve_beads_db)"
    BR_PREFIX=(br --db "$db")
  fi
}

# Fail closed when br --json stdout is a structured error envelope (v0.5.x).
br_json_stdout_check() {
  local raw="$1" context="$2"
  BR_JSON_CONTEXT="$context" python3 -c '
import json, os, sys
raw = sys.stdin.read()
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)
if isinstance(data, dict) and "error" in data:
    err = data.get("error")
    if isinstance(err, dict):
        code = err.get("code") or "BR_ERROR"
        msg = err.get("message") or code
    else:
        code = "BR_ERROR"
        msg = str(err)
    ctx = os.environ.get("BR_JSON_CONTEXT", "br --json")
    sys.stderr.write("[cmdp] error: %s: %s: %s\n" % (ctx, code, msg))
    sys.exit(2)
' <<< "$raw"
}

status_normalize_br_list() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    rows = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: br list --json: not JSON\n")
    sys.exit(2)
if isinstance(rows, dict) and "error" in rows:
    err = rows.get("error")
    if isinstance(err, dict):
        code = err.get("code") or "BR_ERROR"
        msg = err.get("message") or code
    else:
        code = "BR_ERROR"
        msg = str(err)
    sys.stderr.write("[cmdp] error: br list --json: %s: %s\n" % (code, msg))
    sys.exit(2)
if isinstance(rows, dict):
    issues = rows.get("issues")
    if not isinstance(issues, list):
        sys.stderr.write("[cmdp] error: br list --json: envelope missing issues array\n")
        sys.exit(2)
    rows = issues
elif not isinstance(rows, list):
    sys.stderr.write("[cmdp] error: br list --json: expected an array or envelope with issues\n")
    sys.exit(2)
out = []
for r in rows:
    if not isinstance(r, dict):
        sys.stderr.write("[cmdp] error: br list --json: expected objects\n")
        sys.exit(2)
    rid = r.get("id")
    if not rid:
        sys.stderr.write("[cmdp] error: br list --json: missing id\n")
        sys.exit(2)
    out.append({
        "id": str(rid),
        "title": r.get("title"),
        "status": r.get("status"),
        "updated_at": r.get("updated_at"),
        "labels": r.get("labels") if isinstance(r.get("labels"), list) else [],
    })
json.dump(out, sys.stdout)
'
}

# br list with --limit 0 (verification-safe) and normalized issue rows.
br_list_json() {
  local -a args=(list --limit 0)
  args+=("$@")
  local raw
  if ! raw="$("${BR_PREFIX[@]}" "${args[@]}")"; then
    return 1
  fi
  br_json_stdout_check "$raw" "br list --json" || return 1
  printf '%s' "$raw" | status_normalize_br_list
}

status_br_blocked_prefix() {
  if [[ -n "${BR_BLOCKED_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    BR_BLOCKED_PREFIX=($BR_BLOCKED_CMD)
  else
    require_br
    local db
    db="$(resolve_beads_db)"
    BR_BLOCKED_PREFIX=(br --db "$db")
  fi
}

status_normalize_br_blocked() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    rows = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: br blocked --json: not JSON\n")
    sys.exit(2)
if isinstance(rows, dict) and "error" in rows:
    err = rows.get("error")
    if isinstance(err, dict):
        code = err.get("code") or "BR_ERROR"
        msg = err.get("message") or code
    else:
        code = "BR_ERROR"
        msg = str(err)
    sys.stderr.write("[cmdp] error: br blocked --json: %s: %s\n" % (code, msg))
    sys.exit(2)
if isinstance(rows, dict):
    issues = rows.get("issues")
    if issues is None and isinstance(rows.get("data"), list):
        issues = rows.get("data")
    if not isinstance(issues, list):
        sys.stderr.write("[cmdp] error: br blocked --json: envelope missing issues array\n")
        sys.exit(2)
    rows = issues
elif not isinstance(rows, list):
    sys.stderr.write("[cmdp] error: br blocked --json: expected an array or envelope with issues\n")
    sys.exit(2)
out = []
for r in rows:
    if not isinstance(r, dict):
        sys.stderr.write("[cmdp] error: br blocked --json: expected objects\n")
        sys.exit(2)
    rid = r.get("id")
    if not rid:
        sys.stderr.write("[cmdp] error: br blocked --json: missing id\n")
        sys.exit(2)
    blocked_by = r.get("blocked_by")
    if blocked_by is None:
        blocked_by = []
    elif not isinstance(blocked_by, list):
        sys.stderr.write("[cmdp] error: br blocked --json: blocked_by must be an array\n")
        sys.exit(2)
    out.append({
        "id": str(rid),
        "title": r.get("title"),
        "status": r.get("status"),
        "updated_at": r.get("updated_at"),
        "labels": r.get("labels") if isinstance(r.get("labels"), list) else [],
        "blocked_by": [str(x) for x in blocked_by],
        "blocked_by_count": r.get("blocked_by_count"),
    })
json.dump(out, sys.stdout)
'
}

# br blocked with --limit 0 (verification-safe) and normalized rows.
br_blocked_json() {
  local -a args=(blocked --limit 0 --json)
  local raw
  if ! raw="$("${BR_BLOCKED_PREFIX[@]}" "${args[@]}")"; then
    return 1
  fi
  br_json_stdout_check "$raw" "br blocked --json" || return 1
  printf '%s' "$raw" | status_normalize_br_blocked
}

# Best-effort git branch per distinct pane cwd (join step 3: branch == br
# id). command-post's to call, not muxa's — never tmux. Non-git or
# unreadable cwds are simply absent from the map.
status_branch_map() {
  local who="$1"
  local -a cwds=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    cwds+=("$line")
  done < <(printf '%s' "$who" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
seen = set()
for r in rows:
    cwd = r.get("cwd")
    if cwd and cwd not in seen:
        seen.add(cwd)
        print(cwd)
')
  local cwd branch pairs first
  pairs="{"
  first=1
  if [[ ${#cwds[@]} -gt 0 ]]; then
    for cwd in "${cwds[@]}"; do
      branch=""
      if [[ -d "$cwd" ]]; then
        branch="$(git -C "$cwd" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
        if [[ -z "$branch" ]]; then
          branch="$(git -C "$cwd" branch --show-current 2>/dev/null || true)"
        fi
      fi
      [[ -n "$branch" ]] || continue
      if [[ "$first" -eq 0 ]]; then
        pairs+=","
      fi
      first=0
      pairs+="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]) + ": " + json.dumps(sys.argv[2]))' "$cwd" "$branch")"
    done
  fi
  pairs+="}"
  printf '%s' "$pairs"
}

# Candidate ids for the targeted `-s closed` lookup: any jobs.tsv job id, or
# any branch-fallback candidate, not already present in the broad
# open/in_progress list. Skipped entirely (no second br call) when empty.
status_candidate_closed_ids() {
  local jobs_json="$1" br_open_json="$2" branches_json="$3"
  python3 -c '
import json, sys
jobs = json.loads(sys.argv[1])
br_open = json.loads(sys.argv[2])
branches = json.loads(sys.argv[3])
open_ids = {r["id"] for r in br_open}
cand = set()
for j in jobs:
    jid = j.get("job")
    if jid and jid not in open_ids:
        cand.add(jid)
for b in branches.values():
    if b and b not in open_ids:
        cand.add(b)
for c in sorted(cand):
    print(c)
' "$jobs_json" "$br_open_json" "$branches_json"
}

# The join + phase/glyph derivation. See the header comment for the full
# matrix; the orchestrator (parent-null pane, never br-joined by design) is
# judged on activity alone rather than falling into "untracked".
status_assemble() {
  local who="$1" broker="$2" jobs="$3" br_open="$4" br_closed="$5" branches="$6" generated_at="$7" home="$8" stall_sec="$9" origin_filter="${10:-}" br_blocked="${11:-[]}"
  python3 -c '
import datetime, json, sys

who = json.loads(sys.argv[1])
broker = json.loads(sys.argv[2])
jobs = json.loads(sys.argv[3])
br_open = json.loads(sys.argv[4])
br_closed = json.loads(sys.argv[5])
branches = json.loads(sys.argv[6])
generated_at = sys.argv[7]
home = sys.argv[8]
stall_sec = int(sys.argv[9])
origin_filter = sys.argv[10] if len(sys.argv) > 10 else ""
br_blocked = json.loads(sys.argv[11]) if len(sys.argv) > 11 else []

issues = {}
for r in br_open:
    issues[r["id"]] = r
for r in br_closed:
    issues.setdefault(r["id"], r)

jobs_by_worker = {}
jobs_by_worktree = {}
jobs_by_id = {}
for j in jobs:
    jobs_by_id[j["job"]] = j
    if j.get("worker"):
        jobs_by_worker[j["worker"]] = j
    if j.get("worktree"):
        jobs_by_worktree[j["worktree"]] = j

def label_value(labels, prefix):
    for l in labels or []:
        if isinstance(l, str) and l.startswith(prefix):
            return l[len(prefix):]
    return None

def basename(cwd):
    if not cwd:
        return None
    return cwd.rstrip("/").split("/")[-1] or None

PHASE_GLYPH = {
    "working": "dot",
    "waiting": "hollow",
    "held": "ring",
    "stalled": "cross",
    "blocked": "block",
    "done": "check",
    "ghost": "warn",
    "orphaned": "warn",
    "untracked": "dash",
}

def parse_ts(s):
    if not s:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.datetime.strptime(s, fmt).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
    return None

def is_held(pane_state, br_status, job):
    if pane_state != "idle":
        return False
    if br_status not in ("open", "in_progress"):
        return False
    return bool(job and job.get("reported_at"))

def is_stalled(pane_state, br_status, job):
    if pane_state != "idle":
        return False
    if br_status not in ("open", "in_progress"):
        return False
    if not job or not job.get("dispatched_at"):
        return False
    if job.get("reported_at"):
        return False
    dispatched = parse_ts(job["dispatched_at"])
    now = parse_ts(generated_at)
    if dispatched is None or now is None:
        return False
    return (now - dispatched).total_seconds() > stall_sec

def normalize_pane_state(state):
    # unknown/missing state fails toward "needs attention", not silently
    # miscategorized as active.
    return state if state in ("busy", "idle", "ghost") else "ghost"

def normalize_br_status(status):
    return status if status in ("open", "in_progress", "closed") else None

def derive_phase(role, pane_state, br_status):
    if role == "orchestrator" and br_status is None:
        if pane_state == "ghost":
            return "ghost"
        return "working" if pane_state == "busy" else "waiting"
    if pane_state == "ghost":
        return "ghost"
    if pane_state == "gone":
        return "done" if br_status == "closed" else "orphaned"
    if br_status == "closed":
        return "done"
    if br_status in ("in_progress", "open"):
        return "working" if pane_state == "busy" else "waiting"
    return "untracked"

def resolve_timestamp(job, issue):
    if job and job.get("dispatched_at"):
        return job["dispatched_at"], "dispatched_at"
    if issue:
        return issue.get("updated_at"), "br_updated_at"
    return None, None

nodes = []
claimed_ids = set()
root_id = None

for p in who:
    name = p["name"]
    parent = p.get("parent")
    role = "orchestrator" if parent is None else "worker"
    if role == "orchestrator" and root_id is None:
        root_id = name

    pane_state = normalize_pane_state(p.get("state"))
    cwd = p.get("cwd")

    bid = None
    joined_via = None
    issue = None
    job = None

    cand = jobs_by_worker.get(name)
    if cand and cand.get("job") in issues:
        job, bid, joined_via = cand, cand["job"], "jobs.worker"
        issue = issues[bid]

    if issue is None and cwd:
        cand = jobs_by_worktree.get(cwd)
        if cand and cand.get("job") in issues:
            job, bid, joined_via = cand, cand["job"], "jobs.worktree"
            issue = issues[bid]

    branch = job.get("branch") if job else None

    if issue is None and cwd:
        br_cand = branches.get(cwd)
        if br_cand and br_cand in issues:
            bid, joined_via, issue = br_cand, "branch", issues[br_cand]
            branch = br_cand

    br_status = normalize_br_status(issue.get("status") if issue else None)
    title = issue.get("title") if issue else None
    labels = issue.get("labels") if issue else []
    project = label_value(labels, "project:") or basename(cwd)
    delivery = label_value(labels, "delivery:")
    kind_label = label_value(labels, "kind:")
    timestamp, time_source = resolve_timestamp(job, issue)

    phase = derive_phase(role, pane_state, br_status)
    if phase == "waiting" and is_held(pane_state, br_status, job):
        phase = "held"
    elif phase == "waiting" and is_stalled(pane_state, br_status, job):
        phase = "stalled"

    if bid:
        claimed_ids.add(bid)

    nodes.append({
        "id": name,
        "alias": name,
        "role": role,
        "cli": p.get("kind"),
        "pane": p.get("pane"),
        "session": p.get("session"),
        "pane_state": pane_state,
        "drawing": False,
        "br_id": bid,
        "br_status": br_status,
        "phase": phase,
        "glyph": PHASE_GLYPH[phase],
        "title": title,
        "project": project,
        "cwd": cwd,
        "branch": branch,
        "kind": kind_label,
        "delivery": delivery,
        "timestamp": timestamp,
        "time_source": time_source,
        "joined_via": joined_via,
        "_pane_raw": p.get("pane"),
    })

# Every in_progress issue with no live pane becomes an orphaned node so
# in-flight work can never silently vanish from the view.
for iid, issue in issues.items():
    if issue.get("status") != "in_progress" or iid in claimed_ids:
        continue
    job = jobs_by_id.get(iid)
    worker = job.get("worker") if job else None
    node_id = worker or iid
    labels = issue.get("labels") or []
    cwd = job.get("worktree") if job else None
    timestamp, time_source = resolve_timestamp(job, issue)
    nodes.append({
        "id": node_id,
        "alias": node_id,
        "role": "worker",
        "cli": None,
        "pane": None,
        "pane_state": "gone",
        "drawing": False,
        "br_id": iid,
        "br_status": "in_progress",
        "phase": "orphaned",
        "glyph": PHASE_GLYPH["orphaned"],
        "title": issue.get("title"),
        "project": label_value(labels, "project:") or basename(cwd),
        "cwd": cwd,
        "branch": (job.get("branch") if job else None) or iid,
        "kind": label_value(labels, "kind:"),
        "delivery": label_value(labels, "delivery:"),
        "timestamp": timestamp,
        "time_source": time_source,
        "joined_via": None,
        "_pane_raw": None,
    })

pane_to_alias = {n["_pane_raw"]: n["alias"] for n in nodes if n.get("_pane_raw")}
raw_drawing = broker.get("drawing") if isinstance(broker, dict) else None
resolved_drawing = []
drawing_raw_set = set()
if isinstance(raw_drawing, list):
    for pid in raw_drawing:
        drawing_raw_set.add(pid)
        resolved_drawing.append(pane_to_alias.get(pid, pid))

for n in nodes:
    n["drawing"] = bool(n.get("_pane_raw")) and n["_pane_raw"] in drawing_raw_set
    del n["_pane_raw"]

def broker_counter(val):
    return 0 if val is None else val

broker_out = {"ok": bool(isinstance(broker, dict) and broker.get("ok"))}
if broker_out["ok"]:
    broker_out.update({
        "pid": broker.get("pid"),
        "queued": broker_counter(broker.get("queued")),
        "done": broker_counter(broker.get("done")),
        "failed": broker_counter(broker.get("failed")),
        "socket": broker.get("socket"),
        "drawing": resolved_drawing,
    })

node_ids = {n["id"] for n in nodes}
edges = []
for p in who:
    parent = p.get("parent")
    if parent and parent in node_ids and p["name"] in node_ids:
        edges.append({"from": parent, "to": p["name"], "source": "muxa.parent"})

if root_id and root_id in node_ids:
    for n in nodes:
        if n["phase"] == "orphaned":
            edges.append({"from": root_id, "to": n["id"], "source": "inferred"})

if origin_filter:
    job_origin = {j["job"]: j.get("origin") for j in jobs if j.get("origin")}
    allowed_ids = {jid for jid, orig in job_origin.items() if orig == origin_filter}
    blocked_map = {}
    for item in br_blocked:
        bid = item.get("id")
        if bid:
            blocked_map[bid] = item.get("blocked_by") or []

    def blocker_entries(blocker_ids):
        out = []
        for blocker_id in blocker_ids:
            if job_origin.get(blocker_id) == origin_filter:
                iss = issues.get(blocker_id) or {}
                out.append({"id": blocker_id, "title": iss.get("title")})
            else:
                out.append({"id": None, "title": None})
        return out

    nodes = [n for n in nodes if n.get("br_id") in allowed_ids]
    present_ids = {n.get("br_id") for n in nodes if n.get("br_id")}
    for bid in allowed_ids:
        if bid not in blocked_map:
            continue
        entries = blocker_entries(blocked_map[bid])
        if bid in present_ids:
            for n in nodes:
                if n.get("br_id") != bid:
                    continue
                n["phase"] = "blocked"
                n["glyph"] = PHASE_GLYPH["blocked"]
                n["blocked_by"] = entries
                break
        else:
            issue = issues.get(bid) or {}
            job = jobs_by_id.get(bid)
            labels = issue.get("labels") or []
            cwd = job.get("worktree") if job else None
            worker = job.get("worker") if job else bid
            timestamp, time_source = resolve_timestamp(job, issue)
            nodes.append({
                "id": worker,
                "alias": worker,
                "role": "worker",
                "cli": None,
                "pane": None,
                "pane_state": "gone",
                "drawing": False,
                "br_id": bid,
                "br_status": normalize_br_status(issue.get("status")),
                "phase": "blocked",
                "glyph": PHASE_GLYPH["blocked"],
                "title": issue.get("title"),
                "project": label_value(labels, "project:") or basename(cwd),
                "cwd": cwd,
                "branch": (job.get("branch") if job else None) or bid,
                "kind": label_value(labels, "kind:"),
                "delivery": label_value(labels, "delivery:"),
                "timestamp": timestamp,
                "time_source": time_source,
                "joined_via": None,
                "blocked_by": entries,
            })

    node_ids = {n["id"] for n in nodes}
    edges = [e for e in edges if e["from"] in node_ids and e["to"] in node_ids]

result = {
    "v": 1,
    "generated_at": generated_at,
    "home": home,
    "broker": broker_out,
    "nodes": nodes,
    "edges": edges,
}
if origin_filter:
    result["origin"] = origin_filter
json.dump(result, sys.stdout)
' "$who" "$broker" "$jobs" "$br_open" "$br_closed" "$branches" "$generated_at" "$home" "$stall_sec" "$origin_filter" "$br_blocked"
}

status_render_table() {
  python3 -c '
import datetime, json, sys

def broker_counter(val):
    return 0 if val is None else val

data = json.load(sys.stdin)
broker = data.get("broker") or {}
if broker.get("ok"):
    drawing = ",".join(broker.get("drawing") or []) or "-"
    print("BROKER ok queued=%s done=%s failed=%s drawing=%s" % (
        broker_counter(broker.get("queued")),
        broker_counter(broker.get("done")),
        broker_counter(broker.get("failed")),
        drawing))
else:
    print("BROKER degraded (unavailable) -- nodes below may be stale")
print()

def parse_ts(s):
    # br timestamps carry fractional seconds; generated_at/CP_STATUS_NOW do not.
    for fmt in ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.datetime.strptime(s, fmt).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            continue
    return None

def age(ts, now_s):
    if not ts or not now_s:
        return "-"
    t = parse_ts(ts)
    now = parse_ts(now_s)
    if t is None or now is None:
        return "-"
    delta = max(0, int((now - t).total_seconds()))
    if delta < 60:
        return "%ds" % delta
    if delta < 3600:
        return "%dm" % (delta // 60)
    if delta < 86400:
        return "%dh" % (delta // 3600)
    return "%dd" % (delta // 86400)

now_s = data.get("generated_at")
fmt = "%-16s %-12s %-10s %-8s %-16s %-6s %s"
print(fmt % ("ALIAS", "ROLE", "PHASE", "CLI", "PROJECT", "AGE", "TITLE"))
for n in data.get("nodes", []):
    print(fmt % (
        n.get("alias") or "-",
        n.get("role") or "-",
        n.get("phase") or "-",
        n.get("cli") or "-",
        n.get("project") or "-",
        age(n.get("timestamp"), now_s),
        n.get("title") or "-",
    ))
'
}

# Read tracked dashboard assets (Nocturne + fleet layout + shared renderer).
status_dashboard_assets() {
  local asset_dir="$ROOT/lib/status"
  local f
  for f in nocturne.css fleet-dashboard.css dashboard.js; do
    if [[ ! -f "$asset_dir/$f" ]]; then
      die "missing dashboard asset: $asset_dir/$f"
    fi
  done
  STATUS_DASHBOARD_CSS="$(cat "$asset_dir/nocturne.css" "$asset_dir/fleet-dashboard.css")"
  STATUS_DASHBOARD_JS="$(cat "$asset_dir/dashboard.js")"
}

# Self-contained HTML snapshot: embeds the JSON payload verbatim; client-side
# JS reads that blob and renders — no recomputation, no external resources.
status_render_html() {
  local payload="$1"
  status_dashboard_assets
  STATUS_DASHBOARD_CSS="$STATUS_DASHBOARD_CSS" \
  STATUS_DASHBOARD_JS="$STATUS_DASHBOARD_JS" \
  python3 -c '
import json, os, sys

payload = sys.argv[1]
css = os.environ["STATUS_DASHBOARD_CSS"]
js = os.environ["STATUS_DASHBOARD_JS"]

json.loads(payload)
safe = payload.replace("</", "<\\/")

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Command Post Fleet Status</title>
<style>
{css}
</style>
</head>
<body class="fleet-dashboard">
<div id="error-banner" class="error-banner hidden" role="alert"></div>
<div id="app"><p class="text-muted" style="padding:var(--space-4)">Loading fleet status&hellip;</p></div>
<script type="application/json" id="fleet-data">{safe}</script>
<script>
{js}
CPStatusDashboard.boot({{ live: false }});
</script>
</body>
</html>
"""
sys.stdout.write(doc)
' "$payload"
}

# Live dashboard shell: same CSS/render JS as --html, but polls GET /api/status
# every 10s (bgr3 broker interval). Shows a visible banner on fetch failure.
status_render_html_live() {
  status_dashboard_assets
  STATUS_DASHBOARD_CSS="$STATUS_DASHBOARD_CSS" \
  STATUS_DASHBOARD_JS="$STATUS_DASHBOARD_JS" \
  python3 -c '
import os, sys

css = os.environ["STATUS_DASHBOARD_CSS"]
js = os.environ["STATUS_DASHBOARD_JS"]

doc = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Command Post Fleet Status</title>
<style>
{css}
</style>
</head>
<body class="fleet-dashboard">
<div id="error-banner" class="error-banner hidden" role="alert"></div>
<div id="app"><p class="text-muted" style="padding:var(--space-4)">Loading fleet status&hellip;</p></div>
<script>
{js}
CPStatusDashboard.boot({{ live: true }});
</script>
</body>
</html>
"""
sys.stdout.write(doc)
'
}

# Gather muxa/br/jobs facts and assemble the JSON payload (--json stdout).
status_snapshot() {
  local origin_filter="${1:-}"
  local who_json broker_json jobs_json
  who_json="$(status_who_json)"
  broker_json="$(status_broker_json)"
  jobs_json="$(jobs_list_json)"

  local -a BR_PREFIX=()
  status_br_prefix
  local br_open_json
  if ! br_open_json="$(br_list_json --json)"; then
    die "br list --json failed"
  fi

  local branches_json
  branches_json="$(status_branch_map "$who_json")"

  local -a cand_ids=()
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    cand_ids+=("$line")
  done < <(status_candidate_closed_ids "$jobs_json" "$br_open_json" "$branches_json")

  local br_closed_json='[]'
  if [[ ${#cand_ids[@]} -gt 0 ]]; then
    local -a closed_args=(-s closed --json)
    local id
    for id in "${cand_ids[@]}"; do
      closed_args+=(--id "$id")
    done
    if ! br_closed_json="$(br_list_json "${closed_args[@]}")"; then
      die "br list -s closed --json failed"
    fi
  fi

  local blocked_json='[]'
  if [[ -n "$origin_filter" ]]; then
    local -a BR_BLOCKED_PREFIX=()
    status_br_blocked_prefix
    if ! blocked_json="$(br_blocked_json)"; then
      die "br blocked --json failed"
    fi
  fi

  local generated_at="${CP_STATUS_NOW:-}"
  if [[ -z "$generated_at" ]]; then
    generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fi

  local stall_sec="${CP_STATUS_STALL_SEC:-$DEFAULT_STATUS_STALL_SEC}"
  if ! [[ "$stall_sec" =~ ^[0-9]+$ ]] || [[ "$stall_sec" -lt 1 ]]; then
    die_usage "CP_STATUS_STALL_SEC must be a positive integer (got: ${CP_STATUS_STALL_SEC:-})"
  fi

  status_assemble "$who_json" "$broker_json" "$jobs_json" "$br_open_json" "$br_closed_json" "$branches_json" "$generated_at" "$CP_HOME" "$stall_sec" "$origin_filter" "$blocked_json"
}

# One-shot pane scrollback for the dashboard preview modal. muxa tail only on
# demand (never from the status poll). Unknown alias: exit 2 + ok:false JSON.
status_pane_json() {
  local alias="$1"
  [[ -n "$alias" ]] || die "status --pane requires an alias"

  local -a tail_cmd
  if [[ -n "${MUXA_TAIL_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    tail_cmd=($MUXA_TAIL_CMD "$alias")
  else
    require_muxa_bin
    tail_cmd=(muxa tail "$alias" -n 200)
  fi

  local out rc=0
  out="$("${tail_cmd[@]}" 2>/dev/null)" || rc=$?

  printf '%s' "$out" | python3 -c '
import json, sys

alias = sys.argv[1]
rc = int(sys.argv[2])
raw = sys.stdin.read()

if rc == 2:
    json.dump({"ok": False, "error": "unknown pane", "alias": alias}, sys.stdout)
    sys.exit(2)

if rc != 0:
    sys.stderr.write("[cmdp] error: muxa tail failed\n")
    sys.exit(1)

def classify(text):
    t = text.rstrip("\n")
    s = t.lstrip()
    if not s:
        return "dim"
    if s.startswith("#") or s.startswith("//"):
        return "dim"
    if s.startswith("$"):
        return "cmd"
    low = s.lower()
    if "error" in low or "fail" in low or "blocker" in low:
        return "warn"
    if "dispatch" in low or "\u2192" in s or "->" in s:
        return "acc"
    if "ok" in low or "done" in low or "\u2713" in s:
        return "ok"
    return "txt"

lines = [{"kind": classify(line), "text": line} for line in raw.splitlines()]
json.dump({"ok": True, "alias": alias, "lines": lines}, sys.stdout)
' "$alias" "$rc"
}

# Foreground localhost HTTP server. /api/status re-invokes "$PROG status --json".
status_serve() {
  local port="$1"
  export CP_STATUS_PROG="$PROG"
  export CP_STATUS_SERVE_PORT="$port"
  status_render_html_live | python3 -c '
import http.server
import os
import signal
import socketserver
import subprocess
import sys
import threading
from urllib.parse import parse_qs, urlparse

PROG = os.environ["CP_STATUS_PROG"]
PORT = int(os.environ["CP_STATUS_SERVE_PORT"])
HOST = "127.0.0.1"
LIVE_HTML = sys.stdin.read()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, _format, *_args):
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/":
            body = LIVE_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/status":
            try:
                proc = subprocess.run(
                    [PROG, "status", "--json"],
                    capture_output=True,
                    text=True,
                    env=os.environ,
                )
            except OSError as exc:
                self.send_error(502, str(exc))
                return
            if proc.returncode != 0:
                msg = (proc.stderr or proc.stdout or "status --json failed").strip()
                self.send_error(502, msg)
                return
            body = proc.stdout.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif path == "/api/pane":
            qs = parse_qs(parsed.query)
            alias = (qs.get("alias") or [""])[0].strip()
            if not alias:
                self.send_error(400, "missing alias query parameter")
                return
            try:
                proc = subprocess.run(
                    [PROG, "status", "--pane", alias],
                    capture_output=True,
                    text=True,
                    env=os.environ,
                )
            except OSError as exc:
                self.send_error(502, str(exc))
                return
            if proc.returncode == 2:
                body = (proc.stdout or "{\"ok\": false}").encode("utf-8")
                self.send_response(404)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if proc.returncode != 0:
                msg = (proc.stderr or proc.stdout or "status --pane failed").strip()
                self.send_error(502, msg)
                return
            body = proc.stdout.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def main():
    try:
        httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    except OSError as exc:
        print(f"[cmdp] error: cannot bind {HOST}:{PORT} ({exc})", file=sys.stderr)
        sys.exit(2)
    bound_port = httpd.server_address[1]
    print(f"http://127.0.0.1:{bound_port}/", flush=True)
    print("[cmdp] Ctrl-C to stop", file=sys.stderr)

    # serve_forever must not run on the main thread: shutdown() from a signal
    # handler deadlocks when the same thread is blocked inside serve_forever().
    server_thread = threading.Thread(
        target=httpd.serve_forever,
        kwargs={"poll_interval": 0.5},
        name="cp-status-serve",
        daemon=False,
    )

    def shutdown(_signum, _frame):
        httpd.shutdown()

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)
    try:
        signal.signal(signal.SIGHUP, shutdown)
    except (AttributeError, ValueError):
        pass

    server_thread.start()
    server_thread.join()
    httpd.server_close()


if __name__ == "__main__":
    main()
'
}

cmd_status() {
  local json=0 html=0 serve=0 port=8765 pane_alias="" origin_filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)
        json=1
        shift
        ;;
      --html)
        html=1
        shift
        ;;
      --serve)
        serve=1
        shift
        ;;
      --origin)
        [[ $# -ge 2 ]] || die_usage "status --origin needs ID"
        origin_filter="$2"
        shift 2
        ;;
      --pane)
        [[ $# -ge 2 ]] || die_usage "status --pane needs ALIAS"
        pane_alias="$2"
        shift 2
        ;;
      --port)
        [[ $# -ge 2 ]] || die_usage "status --port needs N"
        port="$2"
        shift 2
        ;;
      -h|--help)
        usage_status
        exit 2
        ;;
      *)
        die_usage "unknown status arg $1"
        ;;
    esac
  done

  if [[ -n "$origin_filter" && ( "$serve" -eq 1 || -n "$pane_alias" ) ]]; then
    die_usage "status: --origin is mutually exclusive with --serve and --pane"
  fi

  if [[ -n "$pane_alias" && ( "$serve" -eq 1 || "$json" -eq 1 || "$html" -eq 1 ) ]]; then
    die_usage "status: --pane is mutually exclusive with --json, --html, and --serve"
  fi

  if [[ "$serve" -eq 1 && ( "$json" -eq 1 || "$html" -eq 1 ) ]]; then
    die_usage "status: --serve is mutually exclusive with --json and --html"
  fi

  if [[ "$json" -eq 1 && "$html" -eq 1 ]]; then
    die_usage "status: use only one of --json or --html"
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for status)\n' >&2
    exit 2
  fi

  if [[ -n "$pane_alias" ]]; then
    status_pane_json "$pane_alias"
    exit $?
  fi

  if [[ "$serve" -eq 1 ]]; then
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
      die_usage "status --port must be a non-negative integer (got: $port)"
    fi
    status_serve "$port"
    return
  fi

  local result
  result="$(status_snapshot "$origin_filter")"

  if [[ "$json" -eq 1 ]]; then
    printf '%s\n' "$result"
  elif [[ "$html" -eq 1 ]]; then
    status_render_html "$result"
  else
    printf '%s' "$result" | status_render_table
  fi
}

clis_tsv_path() {
  printf '%s/share/clis.tsv\n' "$ROOT"
}

routing_tsv_path() {
  printf '%s/data/routing.tsv\n' "$CP_HOME"
}

require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for bin/cmdp JSON, brief, gate, status)\n' >&2
    exit 2
  fi
}

# Return 0 when argv0 is listed in share/clis.tsv.
cli_is_supported() {
  local argv0="$1" line a
  local path
  path="$(clis_tsv_path)"
  [[ -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r a _ _ <<< "$line"
    [[ "$a" == "$argv0" ]] && return 0
  done < "$path"
  return 1
}

# Append supported argv0 names (sorted) to array variable named by $1.
list_supported_clis() {
  local out_arr="$1" path line a
  local -a cli_list=()
  path="$(clis_tsv_path)"
  [[ -f "$path" ]] || { eval "${out_arr}=()"; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r a _ _ <<< "$line"
    [[ -n "$a" ]] && cli_list+=("$a")
  done < "$path"
  if [[ ${#cli_list[@]} -gt 0 ]]; then
    IFS=$'\n' cli_list=($(printf '%s\n' "${cli_list[@]}" | sort))
    unset IFS
  fi
  eval "${out_arr}=()"
  local n
  for n in "${cli_list[@]}"; do
    eval "${out_arr}+=(\"\$n\")"
  done
}

cli_kind_receipt() {
  local argv0="$1" line a kind receipt
  local path
  path="$(clis_tsv_path)"
  [[ -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r a kind receipt <<< "$line"
    if [[ "$a" == "$argv0" ]]; then
      printf '%s\t%s\n' "$kind" "$receipt"
      return 0
    fi
  done < "$path"
  return 1
}

# Load forbid rows from data/routing.tsv into FORBID_CLIS array.
load_forbid_clis() {
  local path="$1" line rec
  local -a fields=()
  FORBID_CLIS=()
  [[ -f "$path" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -a fields <<< "$line"
    rec="${fields[0]}"
    [[ "$rec" == forbid && ${#fields[@]} -ge 2 ]] || continue
    FORBID_CLIS+=("${fields[1]}")
  done < "$path"
}

cli_is_forbidden() {
  local want="$1" f
  [[ ${#FORBID_CLIS[@]} -gt 0 ]] || return 1
  for f in "${FORBID_CLIS[@]}"; do
    [[ "$f" == "$want" ]] && return 0
  done
  return 1
}

# Derivation preference when several worker CLIs are installed (documented order).
CLI_DERIVE_PREFERENCE=(agent cursor-agent claude)

cli_default_model() {
  local argv0="$1" line a model
  local path
  path="$(clis_tsv_path)"
  [[ -f "$path" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    IFS=$'\t' read -r a _ _ model <<< "$line"
    if [[ "$a" == "$argv0" ]]; then
      printf '%s' "${model:-}"
      return 0
    fi
  done < "$path"
  return 1
}

# Append installed supported CLIs (not forbidden) to array named by $1.
list_derived_candidates() {
  local out_arr="$1" name p
  local -a supported=()
  load_forbid_clis "$(routing_tsv_path)"
  list_supported_clis supported
  eval "${out_arr}=()"
  for name in "${supported[@]}"; do
    cli_is_forbidden "$name" && continue
    p="$(cmd_v_path "$name")"
    [[ -n "$p" ]] || continue
    eval "${out_arr}+=(\"\$name\")"
  done
}

# Build argv for a CLI using its default_model from share/clis.tsv into array $2.
compose_cli_argv() {
  local cli="$1" out_arr="$2" model
  model="$(cli_default_model "$cli" 2>/dev/null || true)"
  eval "${out_arr}=()"
  eval "${out_arr}+=(\"\$cli\")"
  if [[ -n "$model" ]]; then
    eval "${out_arr}+=(--model \"\$model\")"
  fi
}

# Pick one CLI from installed candidates using CLI_DERIVE_PREFERENCE.
pick_derived_cli() {
  local out_var="$1"
  local -a candidates=() pref=() picked=()
  list_derived_candidates candidates
  if [[ ${#candidates[@]} -eq 0 ]]; then
    eval "${out_var}="
    return 1
  fi
  if [[ ${#candidates[@]} -eq 1 ]]; then
    eval "${out_var}=\${candidates[0]}"
    return 0
  fi
  local c p
  for p in "${CLI_DERIVE_PREFERENCE[@]}"; do
    for c in "${candidates[@]}"; do
      [[ "$c" == "$p" ]] && picked+=("$c")
    done
  done
  for c in "${candidates[@]}"; do
    local seen=0 x
    for x in "${picked[@]}"; do
      [[ "$x" == "$c" ]] && seen=1
    done
    [[ "$seen" -eq 0 ]] && picked+=("$c")
  done
  eval "${out_var}=\${picked[0]}"
}

# Resolve role argv into array variable $2; source into $3; optional reason into $4.
resolve_role_argv() {
  local role="$1" out_arr="$2" out_src="$3" out_reason="${4:-}"
  local path line found=0 src_val="shipped" reason=""
  local -a argv=() shipped=() fields=() candidates=() derived_cli=()

  case "$role" in
    researcher) shipped=("${SHIPPED_RESEARCHER[@]}") ;;
    implementer) shipped=("${SHIPPED_IMPLEMENTER[@]}") ;;
    gate-reviewer) shipped=("${SHIPPED_GATE_REVIEWER[@]}") ;;
    *) die "unknown role $role" ;;
  esac

  load_forbid_clis "$(routing_tsv_path)"

  path="$(routing_tsv_path)"
  if [[ -f "$path" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      IFS=$'\t' read -a fields <<< "$line"
      [[ "${fields[0]}" == forbid ]] && continue
      [[ "${fields[0]}" == "$role" ]] || continue
      argv=()
      local i
      for (( i=1; i<${#fields[@]}; i++ )); do
        argv+=("${fields[$i]}")
      done
      [[ ${#argv[@]} -gt 0 ]] || continue
      found=1
    done < "$path"
  fi

  if [[ "$found" -eq 1 ]]; then
    src_val="routing"
    reason="data/routing.tsv row for role $role"
  elif [[ -n "$(cmd_v_path "${shipped[0]}")" ]] && ! cli_is_forbidden "${shipped[0]}"; then
    argv=("${shipped[@]}")
    src_val="shipped"
    reason="shipped default CLI ${shipped[0]} is installed"
  else
    list_derived_candidates candidates
    if [[ ${#candidates[@]} -eq 1 ]]; then
      compose_cli_argv "${candidates[0]}" argv
      src_val="derived"
      reason="only installed worker CLI: ${candidates[0]}"
    elif [[ ${#candidates[@]} -gt 1 ]]; then
      pick_derived_cli derived_cli
      compose_cli_argv "$derived_cli" argv
      src_val="derived"
      reason="preference order among installed CLIs (picked ${derived_cli})"
    else
      argv=("${shipped[@]}")
      src_val="derived"
      reason="no worker CLI installed"
    fi
  fi

  eval "${out_arr}=()"
  local a
  for a in "${argv[@]}"; do
    eval "${out_arr}+=(\"\$a\")"
  done
  eval "${out_src}=\$src_val"
  if [[ -n "$out_reason" ]]; then
    eval "${out_reason}=\$reason"
  fi
}

announce_routing_resolution() {
  local role="$1" source="$2" reason="$3"
  shift 3
  local -a argv=("$@")
  printf '[cmdp] routing: role=%s argv=%q source=%s (%s)\n' \
    "$role" "${argv[*]}" "$source" "$reason" >&2
}

validate_worker_argv0() {
  local argv0="$1" role="$2" source="$3"
  [[ -f "$(clis_tsv_path)" ]] || die "missing CLI registry: $(clis_tsv_path)"
  if ! cli_is_supported "$argv0"; then
    printf '[cmdp] error: worker CLI %q is not in share/clis.tsv (role=%s, source=%s)\n' \
      "$argv0" "$role" "$source" >&2
    printf 'Use a supported CLI from share/clis.tsv, or pass an explicit -- CMD override.\n' >&2
    printf 'bin/cmdp doctor lists installed CLIs.\n' >&2
    exit 2
  fi
  load_forbid_clis "$(routing_tsv_path)"
  if cli_is_forbidden "$argv0"; then
    printf '[cmdp] error: worker CLI %q is forbidden (forbid row in data/routing.tsv, role=%s)\n' \
      "$argv0" "$role" >&2
    printf 'Remove the forbid row or pick another CLI for that role in data/routing.tsv.\n' >&2
    exit 2
  fi
}

installable_clis_message() {
  local -a installable=()
  list_supported_clis installable
  if [[ ${#installable[@]} -eq 0 ]]; then
    printf 'Install a supported worker CLI listed in share/clis.tsv.\n'
    return 0
  fi
  printf 'Install one of: %s (see share/clis.tsv).\n' "${installable[*]}"
}

require_worker_cmd() {
  local argv0="$1" role="$2" source="$3" p
  local -a candidates=()
  validate_worker_argv0 "$argv0" "$role" "$source"
  p="$(cmd_v_path "$argv0")"
  if [[ -n "$p" ]]; then
    return 0
  fi
  list_derived_candidates candidates
  printf '[cmdp] error: worker CLI %q not on PATH (role=%s, source=%s)\n' \
    "$argv0" "$role" "$source" >&2
  if [[ ${#candidates[@]} -eq 0 ]]; then
    installable_clis_message >&2
  else
    printf "Install %q, or set that role in data/routing.tsv to an installed CLI from share/clis.tsv.\n" \
      "$argv0" >&2
  fi
  printf 'bin/cmdp doctor lists installed CLIs.\n' >&2
  exit 2
}

dispatch_role_from_template() {
  local template="$1"
  if [[ "$template" == research ]]; then
    printf 'researcher\n'
  else
    printf 'implementer\n'
  fi
}

require_treehouse() {
  if ! command -v treehouse >/dev/null 2>&1; then
    printf '[cmdp] error: treehouse not on PATH — run bin/install.sh\n' >&2
    exit 2
  fi
}

require_muxa_bin() {
  if ! command -v muxa >/dev/null 2>&1; then
    printf '[cmdp] error: muxa not on PATH — run bin/install.sh\n' >&2
    exit 2
  fi
}

treehouse_get_lease() {
  local clone="$1" path
  require_treehouse
  path="$( (cd "$clone" && treehouse get --lease) )" \
    || die "treehouse get --lease failed in $clone — register the canonical clone and retry"
  path="${path//$'\r'/}"
  path="$(printf '%s\n' "$path" | awk 'NF{p=$0} END{print p}')"
  [[ -n "$path" ]] || die "treehouse get --lease printed no path — expect the absolute worktree on stdout"
  [[ -d "$path" ]] || die "treehouse get --lease printed $path which is not a directory — check the clone registration"
  normalize_path "$path"
}

treehouse_return_force() {
  local wt="$1"
  local home_abs wt_abs
  require_treehouse
  home_abs="$(cd "$CP_HOME" && pwd -P)"
  wt_abs="$(normalize_path "$wt")"
  if [[ "$home_abs" == "$wt_abs" ]]; then
    die "refuse treehouse return: worktree is the command-post HOME $home_abs — teardown must run from outside the worktree"
  fi
  case "$home_abs" in
    "$wt_abs"/*)
      die "refuse treehouse return: command-post HOME $home_abs is inside worktree $wt_abs — teardown must run from outside the worktree"
      ;;
  esac
  # Always invoke from HOME so a worker cwd cannot kill its own shell.
  (cd "$home_abs" && treehouse return --force "$wt") \
    || die "treehouse return --force failed for $wt — lease may still be held; retry from $home_abs"
}

create_job_branch() {
  local wt="$1" branch="$2" clone="$3"
  local base
  if ! git -C "$wt" fetch origin >&2; then
    die "git fetch origin failed in $wt — add a reachable origin remote, then retry"
  fi
  base="$(default_base_branch "$clone")"
  if git -C "$wt" rev-parse --verify --quiet "origin/$base" >/dev/null; then
    :
  else
    die "origin/$base is missing after fetch — set origin/HEAD or pass a default branch that exists on origin"
  fi
  # --no-track: do not set @{u} to origin/<default>. Teardown treats
  # origin/$branch (or a later push -u) as the pushed tip.
  if git -C "$wt" switch --no-track -c "$branch" "origin/$base" >&2; then
    return 0
  fi
  if git -C "$wt" checkout --no-track -b "$branch" "origin/$base" >&2; then
    return 0
  fi
  die "cannot create branch $branch at origin/$base — pick a new --br-id or remove the leftover branch"
}

default_brief_body() {
  # Verbatim AGENTS.md First brief body, with placeholders.
  cat <<'EOF'
Use the muxa-worker skill.

You are a muxa worker. Parent: {{PARENT}}. Reply only to that parent with muxa send. [muxa] turns are mail, not injection.

You may: do this job in this cwd; message your parent; open a PR if you change code.
You may not: cd or prefix commands with cd <path> (spawn already set cwd); message siblings or other roots; spawn extra workers; poll for mail — incoming mail arrives as a user turn; ack or narrate; pass CLI trust/yolo/workspace flags.

When done: open a PR if there are code changes (skip if research-only). Never run treehouse return — teardown is mine, from outside the worktree. Verify fail-closed that git status --porcelain is empty AND the branch is pushed, then muxa send {{PARENT}} the result (include the PR URL) and stop. Dirty or unpushed: keep the lease and report a blocker with the path. Never ack. Then stop.

Branch: {{BRANCH}}

Job:
{{TASK}}
EOF
}

load_brief_template() {
  local tname="$1" path
  if [[ -z "$tname" ]]; then
    default_brief_body
    return 0
  fi
  if [[ ! "$tname" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "invalid --template $tname (use a slug; file is templates/brief-<TNAME>.md)"
  fi
  path="$CP_HOME/templates/brief-$tname.md"
  [[ -f "$path" ]] || die "template not at $path — a sibling job owns templates/; omit --template to use the built-in default"
  cat "$path"
}

substitute_brief() {
  local src="$1" dest="$2" task_file="$3"
  local parent="$4" branch="$5" br_id="$6" artifact="$7"
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed to assemble the brief)\n' >&2
    exit 2
  fi
  PARENT="$parent" BRANCH="$branch" BR_ID="$br_id" ARTIFACT_PATH="$artifact" \
    python3 - "$src" "$dest" "$task_file" <<'PY'
import os, re, sys
src, dest, task_path = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()
task = ""
if task_path:
    task = open(task_path, encoding="utf-8").read()
pre_repl = {
    "{{PARENT}}": os.environ.get("PARENT", ""),
    "{{BRANCH}}": os.environ.get("BRANCH", ""),
    "{{BR_ID}}": os.environ.get("BR_ID", ""),
    "{{ARTIFACT_PATH}}": os.environ.get("ARTIFACT_PATH", ""),
}
for key, val in pre_repl.items():
    text = text.replace(key, val)
# Guard the template only — {{TASK}} is substituted after this check so
# caller-supplied content (JSX, Handlebars, etc.) is never validated.
left = [m for m in re.findall(r"\{\{[^}]+\}\}", text) if m != "{{TASK}}"]
if left:
    sys.stderr.write(
        "[cmdp] error: placeholder %s left unsubstituted — use {{PARENT}}, {{BRANCH}}, {{BR_ID}}, {{ARTIFACT_PATH}}, {{TASK}}\n"
        % left[0]
    )
    sys.exit(1)
text = text.replace("{{TASK}}", task)
open(dest, "w", encoding="utf-8").write(text)
PY
}

parse_dispatch_json() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '[cmdp] error: python3 not on PATH (needed for muxa dispatch JSON)\n' >&2
    exit 2
  fi
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    obj = json.loads(raw)
except Exception:
    sys.stderr.write("[cmdp] error: muxa dispatch stdout is not JSON (state=dispatched means queued, not received)\n")
    sys.exit(2)
if not isinstance(obj, dict):
    sys.stderr.write("[cmdp] error: muxa dispatch stdout: expected a JSON object\n")
    sys.exit(2)
name = obj.get("name") if obj.get("name") is not None else ""
cwd = obj.get("cwd") if obj.get("cwd") is not None else ""
state = obj.get("state") if obj.get("state") is not None else ""
if str(name) == "":
    sys.stderr.write("[cmdp] error: muxa dispatch JSON missing name\n")
    sys.exit(1)
if "\t" in str(name) or "\n" in str(name) or "\t" in str(cwd) or "\n" in str(cwd) or "\t" in str(state) or "\n" in str(state):
    sys.stderr.write("[cmdp] error: muxa dispatch JSON: field contains a tab or newline\n")
    sys.exit(2)
sys.stdout.write("%s\t%s\t%s\n" % (name, cwd, state))
'
}

emit_dispatch_json() {
  local br_id="$1" worker="$2" worktree="$3" branch="$4" state="$5" receipt="$6"
  python3 -c '
import json, sys
json.dump({
    "br_id": sys.argv[1],
    "worker": sys.argv[2],
    "worktree": sys.argv[3],
    "branch": sys.argv[4],
    "state": sys.argv[5],
    "receipt": sys.argv[6],
}, sys.stdout)
print()
' "$br_id" "$worker" "$worktree" "$branch" "$state" "$receipt"
}

muxa_whoami_name() {
  local self="${MUXA_WHOAMI:-}"
  if [[ -z "$self" ]]; then
    require_muxa_bin
    self="$(muxa whoami 2>/dev/null || true)"
  fi
  [[ -n "$self" ]] || die "muxa whoami is empty — register this pane (muxa hook / muxa register), then retry"
  printf '%s\n' "$self"
}

worker_in_who() {
  local want="$1" line name state cwd
  local -a who_cmd
  if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    who_cmd=($MUXA_WHO_CMD)
  else
    require_muxa_bin
    who_cmd=(muxa who --json)
  fi
  local who_out parsed
  if ! who_out="$("${who_cmd[@]}")"; then
    printf '[cmdp] error: muxa who --json failed\n' >&2
    exit 2
  fi
  if ! parsed="$(printf '%s\n' "$who_out" | who_json_rows)"; then
    exit 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r name state cwd _ <<< "$line"
    if [[ "$name" == "$want" ]]; then
      return 0
    fi
  done <<< "$parsed"
  return 1
}

# Prints the worker's kind (claude|cursor|...) from muxa who --json, or
# empty if the row is absent or carries no kind. This is the only source of
# truth for kind — never infer it from the agent CMD or pane text.
worker_kind() {
  local want="$1" line name state cwd kind
  local -a who_cmd
  if [[ -n "${MUXA_WHO_CMD:-}" ]]; then
    # shellcheck disable=SC2206
    who_cmd=($MUXA_WHO_CMD)
  else
    require_muxa_bin
    who_cmd=(muxa who --json)
  fi
  local who_out parsed
  if ! who_out="$("${who_cmd[@]}")"; then
    printf '[cmdp] error: muxa who --json failed\n' >&2
    exit 2
  fi
  if ! parsed="$(printf '%s\n' "$who_out" | who_json_rows)"; then
    exit 2
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    IFS=$'\t' read -r name state cwd kind <<< "$line"
    if [[ "$name" == "$want" ]]; then
      printf '%s\n' "$kind"
      return 0
    fi
  done <<< "$parsed"
  printf '\n'
}

assert_clean_research() {
  local wt="$1" branch="$2"
  local dirty base ahead upstream local_rev remote_rev
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    printf '[cmdp] error: dirty worktree %s — keep the lease; clean porcelain, then retry teardown\n' "$wt" >&2
    exit 1
  fi
  base="$(default_base_branch "$wt")"
  if git -C "$wt" rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    local_rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    remote_rev="$(git -C "$wt" rev-parse "origin/$branch")"
    if [[ "$local_rev" == "$remote_rev" ]]; then
      return 0
    fi
    printf '[cmdp] error: unpushed %s on %s (local tip != origin/%s) — keep the lease; push, then retry teardown\n' \
      "$wt" "$branch" "$branch" >&2
    exit 1
  fi
  if upstream="$(git -C "$wt" rev-parse --abbrev-ref --verify '@{u}' 2>/dev/null)"; then
    local_rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
    remote_rev="$(git -C "$wt" rev-parse '@{u}')"
    if [[ "$local_rev" != "$remote_rev" ]]; then
      printf '[cmdp] error: unpushed %s on %s (local %s != %s) — keep the lease; push, then retry teardown\n' \
        "$wt" "$branch" "${local_rev:0:12}" "$upstream" >&2
      exit 1
    fi
  fi
  ahead=0
  if git -C "$wt" rev-parse --verify --quiet "$branch" >/dev/null \
    && git -C "$wt" rev-parse --verify --quiet "origin/$base" >/dev/null; then
    ahead="$(git -C "$wt" rev-list --count "origin/$base..$branch" 2>/dev/null || echo 0)"
  fi
  if [[ "$ahead" != "0" ]]; then
    printf '[cmdp] error: research branch %s has %s unpushed commit(s) on %s — keep the lease; reset or push, then retry teardown\n' \
      "$branch" "$ahead" "$wt" >&2
    exit 1
  fi
}

assert_clean_and_pushed() {
  local wt="$1" branch="$2"
  local dirty local_rev remote_rev upstream head_branch base
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    printf '[cmdp] error: dirty worktree %s — keep the lease; clean porcelain, then retry teardown\n' "$wt" >&2
    exit 1
  fi
  local_rev="$(git -C "$wt" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$local_rev" ]] || die "cannot read HEAD in $wt — keep the lease"
  # Spec is OR: matching @{u}, matching origin/$branch, or never-ready
  # (tip equals origin/<default> with no upstream and no origin/$branch).
  if git -C "$wt" rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    remote_rev="$(git -C "$wt" rev-parse "origin/$branch")"
    if [[ "$local_rev" == "$remote_rev" ]]; then
      return 0
    fi
  fi
  if upstream="$(git -C "$wt" rev-parse --abbrev-ref --verify '@{u}' 2>/dev/null)"; then
    remote_rev="$(git -C "$wt" rev-parse '@{u}')"
    if [[ "$local_rev" == "$remote_rev" ]]; then
      return 0
    fi
    printf '[cmdp] error: unpushed %s on %s (local %s != %s) — keep the lease; push, then retry teardown\n' \
      "$wt" "$branch" "${local_rev:0:12}" "$upstream" >&2
    exit 1
  fi
  if git -C "$wt" rev-parse --verify --quiet "origin/$branch" >/dev/null; then
    printf '[cmdp] error: unpushed %s on %s (local tip != origin/%s) — keep the lease; push, then retry teardown\n' \
      "$wt" "$branch" "$branch" >&2
    exit 1
  fi
  head_branch="$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
  if [[ "$head_branch" == "$branch" ]]; then
    base="$(default_base_branch "$wt")"
    if git -C "$wt" rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
      remote_rev="$(git -C "$wt" rev-parse "refs/remotes/origin/$base")"
      if [[ "$local_rev" == "$remote_rev" ]]; then
        return 0
      fi
    fi
  fi
  printf '[cmdp] error: unpushed %s branch %s has no upstream and is not on origin — keep the lease; push, then retry teardown\n' \
    "$wt" "$branch" >&2
  exit 1
}

cmd_dispatch() {
  local project="" br_id="" alias="" template="" task_file=""
  local -a agent_cmd=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project)
        [[ $# -ge 2 ]] || die_usage "--project needs NAME"
        project="$2"
        shift 2
        ;;
      --br-id)
        [[ $# -ge 2 ]] || die_usage "--br-id needs ID"
        br_id="$2"
        shift 2
        ;;
      --name)
        [[ $# -ge 2 ]] || die_usage "--name needs ALIAS"
        alias="$2"
        shift 2
        ;;
      --template)
        [[ $# -ge 2 ]] || die_usage "--template needs TNAME"
        template="$2"
        shift 2
        ;;
      --task-file)
        [[ $# -ge 2 ]] || die_usage "--task-file needs FILE"
        task_file="$2"
        shift 2
        ;;
      -h|--help)
        usage_dispatch
        exit 2
        ;;
      --)
        shift
        agent_cmd+=("$@")
        break
        ;;
      -*)
        die_usage "unknown flag $1"
        ;;
      *)
        die_usage "unexpected arg $1 (command after -- )"
        ;;
    esac
  done

  [[ -n "$project" ]] || die_usage "missing --project NAME"
  [[ -n "$br_id" ]] || die_usage "missing --br-id ID"
  validate_job_id "$br_id"
  if [[ -n "$task_file" && ! -f "$task_file" ]]; then
    die "--task-file $task_file is not a file — pass a readable path"
  fi

  local role source override=0 route_reason=""
  if [[ ${#agent_cmd[@]} -eq 0 ]]; then
    role="$(dispatch_role_from_template "$template")"
    resolve_role_argv "$role" agent_cmd source route_reason
    announce_routing_resolution "$role" "$source" "$route_reason" "${agent_cmd[@]}"
  else
    override=1
    role="$(dispatch_role_from_template "$template")"
    source="override"
    announce_routing_resolution "$role" "$source" "explicit -- CMD override" "${agent_cmd[@]}"
  fi

  local clone wt branch parent artifact brief_src brief_out parsed
  local worker json_cwd json_state receipt
  # Trap state must be global: EXIT runs after this function's locals are gone.
  DISPATCH_KEEP_LEASE=0
  DISPATCH_LEASED_WT=""
  clone="$(assert_canonical_clone "$project")" || exit $?

  require_python3
  require_muxa
  require_worker_cmd "${agent_cmd[0]}" "$role" "$source"

  wt="$(treehouse_get_lease "$clone")"
  DISPATCH_LEASED_WT="$wt"
  cleanup_lease() {
    if [[ "${DISPATCH_KEEP_LEASE:-0}" -eq 0 && -n "${DISPATCH_LEASED_WT:-}" ]]; then
      # Do not die() from EXIT — a failed return must not re-enter this trap.
      if command -v treehouse >/dev/null 2>&1; then
        home_abs="$(cd "$CP_HOME" && pwd -P)"
        (cd "$home_abs" && treehouse return --force "$DISPATCH_LEASED_WT") >&2 \
          || printf '[cmdp] error: treehouse return --force failed for %s during cleanup — lease may still be held\n' "$DISPATCH_LEASED_WT" >&2
      fi
    fi
  }
  trap cleanup_lease EXIT

  if ! create_job_branch "$wt" "$br_id" "$clone"; then
    exit 1
  fi
  branch="$br_id"

  if ! "$PROG" check --project "$project" "$wt" >&2; then
    die "bin/cmdp check failed for $wt — returned the lease; fix the precheck, then retry"
  fi

  parent="$(muxa_whoami_name)"
  artifact="$(artifact_report "$br_id")"
  if [[ "$artifact" != /* ]]; then
    artifact="$(cd "$CP_HOME" && pwd)/state/artifacts/${br_id}/report.md"
  fi

  brief_src="$(mktemp)"
  brief_out="$(mktemp)"
  load_brief_template "$template" > "$brief_src"
  if ! substitute_brief "$brief_src" "$brief_out" "$task_file" "$parent" "$branch" "$br_id" "$artifact"; then
    rm -f "$brief_src" "$brief_out"
    die "brief assembly failed — fix the template placeholders, then retry"
  fi
  rm -f "$brief_src"

  require_muxa_bin
  local -a dispatch_cmd
  dispatch_cmd=(muxa dispatch)
  if [[ -n "$alias" ]]; then
    dispatch_cmd+=(--name "$alias")
  fi
  dispatch_cmd+=(--cwd "$wt" --brief-file "$brief_out" --)
  dispatch_cmd+=("${agent_cmd[@]}")

  local out dispatch_err
  dispatch_err="$(mktemp)"
  if ! out="$("${dispatch_cmd[@]}" 2>"$dispatch_err")"; then
    rm -f "$brief_out" "$dispatch_err"
    die "muxa dispatch failed — returned the lease; do not retry from this command (never-ready is orchestrator mail)"
  fi
  if ! dispatch_occupancy_warning_contradiction "$dispatch_err"; then
    dispatch_kill_orphan_pane "$out" || true
    rm -f "$brief_out" "$dispatch_err"
    if [[ "${DISPATCH_KEEP_LEASE:-0}" -eq 1 ]]; then
      die "occupancy contradiction — lease kept; fix muxa kill or inspect with muxa tail before retry"
    fi
    die "occupancy contradiction — returned the lease; inspect with muxa tail before retry"
  fi
  rm -f "$dispatch_err"
  rm -f "$brief_out"
  # Exit 0: the pane exists and the brief is queued. Never return the lease
  # from here — even if JSON parse or jobs add fails.
  DISPATCH_KEEP_LEASE=1

  if ! parsed="$(printf '%s\n' "$out" | parse_dispatch_json)"; then
    exit $?
  fi
  IFS=$'\t' read -r worker json_cwd json_state _ <<< "$parsed"

  local json_cwd_norm="$json_cwd"
  if [[ -d "$json_cwd" ]]; then
    json_cwd_norm="$(normalize_path "$json_cwd")"
  fi
  if [[ "$json_cwd_norm" != "$wt" ]]; then
    die "muxa dispatch cwd $json_cwd != leased worktree $wt — do not retype paths; occupancy may be live (worker $worker)"
  fi

  jobs_add "$br_id" "worker=$worker" "worktree=$wt" "branch=$branch" "origin=terminal" >&2

  receipt="unconfirmed"
  local pane_kind tail_out="" tail_rc=0
  pane_kind="$(worker_kind "$worker")"
  tail_out="$(muxa tail "$worker")" || tail_rc=$?
  # One tail only, ever — kind-aware from here (br command-post-6wco).
  if [[ "$pane_kind" == "claude" ]]; then
    # claude consumes the pasted brief into its conversation instead of
    # echoing it, so "Branch: $branch" never stays visible; and its footer
    # always renders cwd+branch regardless of receipt (the branch is
    # created on the worktree before the paste), so a bare "$branch" match
    # is a false positive, not evidence. Real signal: the footer's
    # "Context: N%" — nonzero only once the brief has been consumed.
    # A single read can't tell "not received" from "still booting" (claude's
    # boot is slow enough to look identical to a drop), so a zero/absent
    # reading here is reported as receipt=unknown, never unconfirmed —
    # unconfirmed would read as "checked, not there"; unknown says "this one
    # check could not tell either way." Do not loop tail to resolve it.
    local ctx_pct=""
    if [[ "$tail_rc" -eq 0 ]]; then
      ctx_pct="$(printf '%s\n' "$tail_out" \
        | grep -Eo 'Context: *[0-9]+(\.[0-9]+)?%' | tail -n1 \
        | grep -Eo '[0-9]+(\.[0-9]+)?' || true)"
    fi
    if [[ -n "$ctx_pct" ]] && awk -v v="$ctx_pct" 'BEGIN{exit !(v>0)}'; then
      receipt="confirmed"
    else
      receipt="unknown"
    fi
  else
    # Cursor (and any other non-claude kind): unchanged. Cursor panes
    # collapse the pasted brief to "[Pasted text]" but still render the
    # bare branch in the footer (path · branch) — kept as receipt evidence
    # for this kind only; do not generalize the bare match to claude.
    if [[ "$tail_rc" -eq 0 ]] && printf '%s\n' "$tail_out" | grep -F -q -- "Branch: $branch"; then
      receipt="confirmed"
    elif [[ "$tail_rc" -eq 0 ]] && printf '%s\n' "$tail_out" | grep -F -q -- "$branch"; then
      receipt="confirmed"
    fi
  fi

  [[ -n "$json_state" ]] || json_state="dispatched"
  trap - EXIT
  emit_dispatch_json "$br_id" "$worker" "$wt" "$branch" "$json_state" "$receipt"
}

doctor_roles_json() {
  local role source
  local -a role_argv=()
  require_python3
  {
    for role in researcher implementer gate-reviewer; do
      resolve_role_argv "$role" role_argv source
      printf '%s\t%s' "$role" "$source"
      local a
      for a in "${role_argv[@]}"; do
        printf '\t%s' "$a"
      done
      printf '\n'
    done
  } | python3 -c '
import json, sys
roles = {}
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    role, source = parts[0], parts[1]
    argv = parts[2:]
    roles[role] = {
        "argv": argv,
        "argv0": argv[0] if argv else "",
        "source": source,
    }
print(json.dumps(roles))
'
}

cmd_doctor() {
  local json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json) json=1; shift ;;
      -h|--help) usage_doctor; exit 2 ;;
      --) shift; break ;;
      -*) die_doctor_usage "unknown flag $1" ;;
      *) die_doctor_usage "unexpected arg $1" ;;
    esac
  done
  [[ $# -eq 0 ]] || die_doctor_usage "doctor takes no arguments"

  local -a host_tools=(python3 muxa br treehouse git tmux)
  local br_slug_ok=0 br_version_ok=0 br_tracker_ok=0 muxa_version_ok=0
  if br_create_supports_slug; then
    br_slug_ok=1
  fi
  if br_version_matches; then
    br_version_ok=1
  fi
  if muxa_version_matches; then
    muxa_version_ok=1
  fi
  if [[ -f "$CP_HOME/.beads/beads.db" ]]; then
    if br --db "$CP_HOME/.beads/beads.db" list --json >/dev/null 2>&1; then
      br_tracker_ok=1
    fi
  else
    br_tracker_ok=1
  fi
  local -a cli_names=() forbid=()
  local name role source kr
  local -a role_argv=()
  local host_missing=0 ht p

  list_supported_clis cli_names

  load_forbid_clis "$(routing_tsv_path)"
  if [[ ${#FORBID_CLIS[@]} -gt 0 ]]; then
    forbid=("${FORBID_CLIS[@]}")
  fi

  host_missing=0
  for ht in "${host_tools[@]}"; do
    if [[ "$ht" == muxa && ( -n "${MUXA_WHO_CMD:-}" || -n "$(cmd_v_path muxa)" ) ]]; then
      continue
    fi
    if [[ -z "$(cmd_v_path "$ht")" ]]; then
      host_missing=1
    fi
  done

  if [[ "$json" -eq 1 ]]; then
    require_python3
    export CP_DOCTOR_ROOT="$ROOT" CP_DOCTOR_HOME="$CP_HOME"
    export CP_DOCTOR_ROLES_JSON
    CP_DOCTOR_ROLES_JSON="$(doctor_roles_json)"
    export CP_DOCTOR_BR_PINNED_VERSION="$(cp_br_pinned_version)"
    export CP_DOCTOR_MUXA_PINNED_VERSION="$(cp_muxa_pinned_version)"
    export CP_DOCTOR_BR_SLUG_OK="$br_slug_ok"
    export CP_DOCTOR_BR_VERSION_OK="$br_version_ok"
    export CP_DOCTOR_MUXA_VERSION_OK="$muxa_version_ok"
    export CP_DOCTOR_BR_TRACKER_OK="$br_tracker_ok"
    python3 - "$ROOT" "$CP_HOME" "$host_missing" <<'PY'
import json, os, subprocess, sys

root, home, host_missing = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
clis_path = os.path.join(root, "share", "clis.tsv")
routing_path = os.path.join(home, "data", "routing.tsv")
roles_base = json.loads(os.environ.get("CP_DOCTOR_ROLES_JSON", "{}"))

def path_of(cmd):
    try:
        env = os.environ.copy()
        out = subprocess.run(["bash", "-c", f"command -v {cmd}"], capture_output=True, text=True, env=env)
        p = out.stdout.strip()
        return p if out.returncode == 0 and p else None
    except Exception:
        return None

host_tools = ["python3", "muxa", "br", "treehouse", "git", "tmux"]
host = {}
for ht in host_tools:
    p = path_of(ht)
    host[ht] = {"ok": p is not None, "path": p or ""}
if host.get("muxa", {}).get("ok"):
    host["muxa"]["version_ok"] = os.environ.get("CP_DOCTOR_MUXA_VERSION_OK") == "1"
if host.get("br", {}).get("ok"):
    host["br"]["create_slug"] = os.environ.get("CP_DOCTOR_BR_SLUG_OK") == "1"
    host["br"]["version_ok"] = os.environ.get("CP_DOCTOR_BR_VERSION_OK") == "1"
    host["br"]["tracker_ok"] = os.environ.get("CP_DOCTOR_BR_TRACKER_OK") == "1"

clis = {}
if os.path.isfile(clis_path):
    with open(clis_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) >= 3:
                argv0, kind, receipt = parts[0], parts[1], parts[2]
                p = path_of(argv0)
                clis[argv0] = {
                    "kind": kind,
                    "receipt": receipt,
                    "installed": p is not None,
                    "path": p or "",
                }

forbid = []
if os.path.isfile(routing_path):
    with open(routing_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if parts[0] == "forbid" and len(parts) >= 2:
                forbid.append(parts[1])

roles = {}
for role, cfg in roles_base.items():
    argv = cfg.get("argv") or []
    argv0 = cfg.get("argv0") or (argv[0] if argv else "")
    p = path_of(argv0) if argv0 else None
    roles[role] = {
        "argv": argv,
        "argv0": argv0,
        "source": cfg.get("source", "shipped"),
        "installed": p is not None,
        "path": p or "",
        "forbidden": argv0 in forbid,
    }

missing = []
for ht, info in host.items():
    if not info["ok"]:
        missing.append({"what": ht, "kind": "host", "fix": f"install {ht} (bin/install.sh for muxa, br, treehouse)"})
if host.get("muxa", {}).get("ok") and not host["muxa"].get("version_ok"):
    pinned = os.environ.get("CP_DOCTOR_MUXA_PINNED_VERSION", "")
    missing.append({
        "what": f"muxa {pinned}" if pinned else "muxa pinned version",
        "kind": "host-version",
        "fix": f"run bin/install.sh (pins muxa {pinned})" if pinned else "run bin/install.sh",
    })
if host.get("br", {}).get("ok") and not host["br"].get("create_slug"):
    missing.append({
        "what": "br --slug",
        "kind": "host-feature",
        "fix": "run bin/install.sh (AGENTS.md intake requires --slug on br create)",
    })
if host.get("br", {}).get("ok") and not host["br"].get("version_ok"):
    pinned = os.environ.get("CP_DOCTOR_BR_PINNED_VERSION", "")
    missing.append({
        "what": f"br {pinned}" if pinned else "br pinned version",
        "kind": "host-version",
        "fix": f"run bin/install.sh (pins beads_rust v{pinned})" if pinned else "run bin/install.sh",
    })
if host.get("br", {}).get("ok") and not host["br"].get("tracker_ok"):
    missing.append({
        "what": "br tracker schema",
        "kind": "host-schema",
        "fix": "br --db <home>/.beads/beads.db doctor migrate-schema plan (then apply --plan-token)",
    })
seen = set()
for role, rinfo in roles.items():
    argv0 = rinfo["argv0"]
    if argv0 and not rinfo["installed"] and argv0 not in seen:
        seen.add(argv0)
        fix = f"install {argv0} or edit data/routing.tsv for role {role}"
        if rinfo["source"] == "derived":
            names = sorted(clis.keys()) if clis else []
            if names:
                fix = f"install one of: {', '.join(names)} (see share/clis.tsv)"
        missing.append({
            "what": argv0,
            "kind": "routed-but-missing",
            "role": role,
            "source": rinfo["source"],
            "fix": fix,
        })

out = {
    "home": home,
    "host": host,
    "clis": clis,
    "roles": roles,
    "forbid": forbid,
    "missing": missing,
}
print(json.dumps(out))
PY
    exit $(( host_missing || muxa_version_ok == 0 || br_slug_ok == 0 || br_version_ok == 0 || br_tracker_ok == 0 ? 2 : 0 ))
  fi

  printf 'command-post home: %s\n' "$CP_HOME"
  printf '\nHost tools:\n'
  for ht in "${host_tools[@]}"; do
    p="$(cmd_v_path "$ht")"
    if [[ -n "$p" || ( "$ht" == muxa && -n "${MUXA_WHO_CMD:-}" ) ]]; then
      printf '  %s: ok (%s)\n' "$ht" "${p:-shim}"
    else
      printf '  %s: MISSING\n' "$ht"
    fi
  done
  printf '\nSupported worker CLIs (share/clis.tsv):\n'
  for name in "${cli_names[@]}"; do
    p="$(cmd_v_path "$name")"
    kr="$(cli_kind_receipt "$name" 2>/dev/null || printf '\t\n')"
    IFS=$'\t' read -r _kind _receipt <<< "$kr"
    if [[ -n "$p" ]]; then
      printf '  %s (%s/%s): ok (%s)\n' "$name" "$_kind" "$_receipt" "$p"
    else
      printf '  %s (%s/%s): missing\n' "$name" "$_kind" "$_receipt"
    fi
  done
  printf '\nRouting:\n'
  for role in researcher implementer gate-reviewer; do
    resolve_role_argv "$role" role_argv source
    p="$(cmd_v_path "${role_argv[0]}")"
    printf '  %s: %s (source=%s)' "$role" "${role_argv[*]}" "$source"
    if cli_is_forbidden "${role_argv[0]}"; then
      printf ' FORBIDDEN'
    elif [[ -n "$p" ]]; then
      printf ' ok'
    else
      printf ' MISSING'
    fi
    printf '\n'
  done
  if [[ ${#forbid[@]} -gt 0 ]]; then
    printf '\nForbid: %s\n' "${forbid[*]}"
  fi
  if [[ "$host_missing" -ne 0 ]]; then
    printf '\n[cmdp] error: one or more host tools are missing — run bin/install.sh\n' >&2
    exit 2
  fi
  if [[ "$muxa_version_ok" -eq 0 ]]; then
    printf '\n[cmdp] error: muxa is not %s — run bin/install.sh (pins muxa %s)\n' \
      "$(cp_muxa_pinned_version)" "$(cp_muxa_pinned_version)" >&2
    exit 2
  fi
  if [[ "$br_slug_ok" -eq 0 ]]; then
    printf '\n[cmdp] error: br create lacks --slug — run bin/install.sh (AGENTS.md intake requires it)\n' >&2
    exit 2
  fi
  if [[ "$br_version_ok" -eq 0 ]]; then
    printf '\n[cmdp] error: br is not %s — run bin/install.sh (pins beads_rust v%s)\n' \
      "$(cp_br_pinned_version)" "$(cp_br_pinned_version)" >&2
    exit 2
  fi
  if [[ "$br_tracker_ok" -eq 0 ]]; then
    printf '\n[cmdp] error: home tracker schema mismatch — run: br --db %s doctor migrate-schema plan\n' \
      "$CP_HOME/.beads/beads.db" >&2
    exit 2
  fi
}

br_create_supports_slug() {
  command -v br >/dev/null 2>&1 \
    && br create --help 2>/dev/null | grep -q -- '--slug <SLUG>'
}

# Pinned muxa release — single source: bin/install.sh MUXA_VERSION_PIN.
cp_muxa_pinned_version() {
  if [[ -n "${CP_MUXA_VERSION_PIN:-}" ]]; then
    printf '%s' "$CP_MUXA_VERSION_PIN"
    return 0
  fi
  local pin
  pin="$(sed -n 's/^MUXA_VERSION_PIN="\(.*\)"/\1/p' "$ROOT/bin/install.sh" | head -1)"
  CP_MUXA_VERSION_PIN="$pin"
  printf '%s' "$pin"
}

muxa_version_matches() {
  command -v muxa >/dev/null 2>&1 || return 1
  local ver
  ver="$(muxa version 2>/dev/null | awk '{print $1}')"
  [[ "$ver" == "$(cp_muxa_pinned_version)" ]]
}

# Pinned br release — single source: bin/install.sh BR_VERSION_PIN.
cp_br_pinned_version() {
  if [[ -n "${CP_BR_VERSION_PIN:-}" ]]; then
    printf '%s' "${CP_BR_VERSION_PIN#v}"
    return 0
  fi
  local pin
  pin="$(sed -n 's/^BR_VERSION_PIN="\(.*\)"/\1/p' "$ROOT/bin/install.sh" | head -1)"
  CP_BR_VERSION_PIN="$pin"
  printf '%s' "${pin#v}"
}

br_version_matches() {
  command -v br >/dev/null 2>&1 || return 1
  [[ "$(br --version 2>/dev/null)" == "br $(cp_br_pinned_version)" ]]
}

cmd_teardown() {
  local id="" research_flag=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage_teardown
        exit 2
        ;;
      --research)
        research_flag=1
        shift
        ;;
      -*)
        die_usage "unknown flag $1"
        ;;
      *)
        [[ -z "$id" ]] || die_usage "teardown takes one ID"
        id="$1"
        shift
        ;;
    esac
  done
  [[ -n "$id" ]] || die_usage "teardown needs ID"
  validate_job_id "$id"

  local row job worker worktree branch kind=""
  row="$(jobs_lookup "$id")" || die "no runtime row for $id — nothing to tear down (bin/cmdp jobs list)"
  IFS=$'\t' read -r job worker worktree branch _ <<< "$row"
  [[ -n "$worktree" ]] || die "runtime row $id has an empty worktree — keep the lease; fix bin/cmdp jobs"
  [[ -n "$worker" ]] || die "runtime row $id has an empty worker — keep the lease; fix bin/cmdp jobs"
  [[ -n "$branch" ]] || die "runtime row $id has an empty branch — keep the lease; fix bin/cmdp jobs"
  [[ -d "$worktree" ]] || die "worktree $worktree is missing — keep the lease; restore the path or fix the jobs row"

  if [[ "$research_flag" -eq 1 ]]; then
    kind="research"
  elif kind="$(br_issue_label_value "$id" "kind:" 2>/dev/null)"; then
    :
  else
    kind=""
  fi
  if [[ "$kind" == "research" ]]; then
    assert_clean_research "$worktree" "$branch"
  else
    assert_clean_and_pushed "$worktree" "$branch"
  fi
  artifact_teardown_guard "$id"
  treehouse_return_force "$worktree"

  if worker_in_who "$worker"; then
    require_muxa_bin
    muxa kill "$worker" || true
  fi

  jobs_done "$id" >&2

  artifact_teardown_clean "$id"
}

main() {
  [[ $# -gt 0 ]] || usage
  case "$1" in
    check)
      shift
      cmd_check "$@"
      ;;
    lease)
      shift
      cmd_lease "$@"
      ;;
    jobs)
      shift
      cmd_jobs "$@"
      ;;
    artifact)
      shift
      cmd_artifact "$@"
      ;;
    gate)
      shift
      cmd_gate "$@"
      ;;
    dispatch)
      shift
      cmd_dispatch "$@"
      ;;
    doctor)
      shift
      cmd_doctor "$@"
      ;;
    teardown)
      shift
      cmd_teardown "$@"
      ;;
    status)
      shift
      cmd_status "$@"
      ;;
    -h|--help)
      usage
      ;;
    *)
      die_usage "unknown command $1 (want: check, lease, jobs, artifact, gate, dispatch, doctor, teardown, or status)"
      ;;
  esac
}

main "$@"
