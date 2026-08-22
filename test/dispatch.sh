#!/usr/bin/env bash
# Unit tests for bin/cp dispatch. muxa and treehouse are PATH shims; git
# runs against temp clones. Never touches the live broker, HOME .beads,
# or real worktrees. Run: test/dispatch.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$ROOT/bin/cp"
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

expect_rc_msg() {
  local want="$1" needle="$2" label="$3"
  shift 3
  local rc=0 out
  out="$("$@" 2>&1)" || rc=$?
  if [[ "$rc" -ne "$want" ]]; then
    fail "$label (want exit $want, got $rc; out: $out)"
    return 0
  fi
  if [[ -n "$needle" ]] && ! printf '%s\n' "$out" | grep -F -q -- "$needle"; then
    fail "$label (missing $(printf %q "$needle"); out: $out)"
    return 0
  fi
  ok "$label (exit $want)"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-dispatch.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
export BR_SHOW_CMD=true
export MUXA_WHOAMI=test-parent
export CP_TEST_WHO="$TMP/who.json"
export CP_TEST_TAIL="$TMP/tail.txt"
export CP_TEST_LEASE="$TMP/leased"
export CP_TEST_TH_LOG="$TMP/treehouse.log"
export CP_TEST_DISPATCH_LOG="$TMP/dispatch.log"
export CP_TEST_KILL_LOG="$TMP/kill.log"
export CP_TEST_BRIEF_COPY="$TMP/brief.copied"
mkdir -p "$CP_HOME" "$TMP/shim"
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TAIL"
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_DISPATCH_LOG"
: > "$CP_TEST_KILL_LOG"

make_clone() {
  local dest="$1" branch="${2:-main}"
  mkdir -p "$dest"
  git -C "$dest" init -q -b "$branch"
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
}

CLONE="$CP_HOME/projects/demo"
make_clone "$CLONE"
CLONE="$(cd "$CLONE" && pwd -P)"
git init -q --bare "$TMP/origin.git"
git -C "$CLONE" remote add origin "$TMP/origin.git"
git -C "$CLONE" push -q -u origin main
git -C "$CLONE" remote set-head origin main
git -C "$CLONE" worktree add --detach -q "$TMP/leased" >/dev/null
LEASE="$(cd "$TMP/leased" && pwd -P)"
export CP_TEST_LEASE="$LEASE"

cat > "$TMP/shim/muxa" <<'EOF'
#!/bin/sh
set -eu
cmd="$1"
shift
case "$cmd" in
  who)
    cat "${CP_TEST_WHO:?}"
    ;;
  whoami)
    printf '%s\n' "${MUXA_WHOAMI:-test-parent}"
    ;;
  dispatch)
    printf '%s\n' "$*" > "${CP_TEST_DISPATCH_LOG:?}"
    cwd=""
    brief=""
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --brief-file) brief="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
      esac
    done
    if [ -n "$brief" ] && [ -f "$brief" ]; then
      cp "$brief" "${CP_TEST_BRIEF_COPY:?}"
    fi
    if [ -n "${CP_TEST_DISPATCH_CWD:-}" ]; then
      cwd="$CP_TEST_DISPATCH_CWD"
    fi
    [ -n "$name" ] || name="swift-oak"
    printf '{"name":"%s","id":"abc","pane":"%%1","cwd":"%s","state":"dispatched","from":"test-parent","to":"%s"}\n' \
      "$name" "$cwd" "$name"
    ;;
  tail)
    cat "${CP_TEST_TAIL:?}"
    ;;
  kill)
    printf '%s\n' "$*" >> "${CP_TEST_KILL_LOG:?}"
    ;;
  *)
    printf 'muxa shim: unexpected %s\n' "$cmd" >&2
    exit 2
    ;;
esac
EOF

cat > "$TMP/shim/treehouse" <<'EOF'
#!/bin/sh
set -eu
printf 'cwd=%s args=%s\n' "$(pwd)" "$*" >> "${CP_TEST_TH_LOG:?}"
case "$1" in
  get)
    printf '%s\n' "${CP_TEST_LEASE:?}"
    ;;
  return)
    ;;
  *)
    printf 'treehouse shim: unexpected %s\n' "$1" >&2
    exit 2
    ;;
esac
EOF

chmod +x "$TMP/shim/muxa" "$TMP/shim/treehouse"
export PATH="$TMP/shim:$PATH"

printf 'do the work\n' > "$TMP/task.txt"

reset_logs() {
  : > "$CP_TEST_TH_LOG"
  : > "$CP_TEST_DISPATCH_LOG"
  : > "$CP_TEST_KILL_LOG"
  rm -f "$CP_TEST_BRIEF_COPY"
  printf '[]\n' > "$CP_TEST_WHO"
  : > "$CP_TEST_TAIL"
  unset CP_TEST_DISPATCH_CWD || true
  rm -f "$CP_JOBS_FILE"
}

# help names the unconfirmed success outcome
expect_rc_msg 2 "receipt=unconfirmed" "dispatch help names receipt=unconfirmed" \
  "$CP" dispatch --help
expect_rc_msg 2 "never re-dispatch" "dispatch help says never re-dispatch" \
  "$CP" dispatch --help
expect_rc_msg 2 "queued, not received" "dispatch help says queued not received" \
  "$CP" dispatch --help

# promote-not-spawn: live worker on a project worktree; no lease
reset_logs
cat > "$CP_TEST_WHO" <<EOF
[{"name":"idle-auk","id":"abc","parent":null,"kind":"cursor","state":"idle","pane":"%1","session":null,"cwd":"$CLONE"}]
EOF
expect_rc_msg 1 "promote-not-spawn: live worker idle-auk occupies" \
  "idle occupant on the project is promote-not-spawn" \
  "$CP" dispatch --project demo --br-id job-promo --task-file "$TMP/task.txt"
if grep -q 'get' "$CP_TEST_TH_LOG"; then
  fail "promote-not-spawn does not call treehouse get"
else
  ok "promote-not-spawn does not call treehouse get"
fi

# missing project
reset_logs
expect_rc_msg 1 "project clone not at" "missing projects/<name> is refused" \
  env CP_HOME="$TMP/empty" CP_JOBS_FILE="$TMP/empty/state/jobs.tsv" \
  BR_SHOW_CMD=true MUXA_WHOAMI=test-parent \
  "$CP" dispatch --project missing --br-id job-miss --task-file "$TMP/task.txt"

# happy path: lease captured, branch created, jobs recorded, receipt confirmed
reset_logs
printf 'Branch: job-ok\nvisible brief\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-ok --task-file "$TMP/task.txt" 2>"$TMP/err.ok")" || {
  fail "happy path dispatch (exit $? err=$(cat "$TMP/err.ok"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c '
import json, sys
o = json.load(sys.stdin)
assert o["br_id"] == "job-ok"
assert o["worker"] == "swift-oak"
assert o["branch"] == "job-ok"
assert o["state"] == "dispatched"
assert o["receipt"] == "confirmed"
assert o["worktree"]
'; then
  ok "happy path stdout is the dispatch JSON with receipt=confirmed"
else
  fail "happy path JSON (out=$out err=$(cat "$TMP/err.ok"))"
fi
if grep -F -q -- "Branch: job-ok" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "do the work" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "Parent: test-parent" "$CP_TEST_BRIEF_COPY"; then
  ok "built-in brief substitutes PARENT, BRANCH, TASK"
else
  fail "built-in brief substitutes (brief=$(cat "$CP_TEST_BRIEF_COPY" 2>/dev/null))"
fi
if grep -F -q -- "--cwd $LEASE" "$CP_TEST_DISPATCH_LOG" \
  && grep -F -q -- "--brief-file" "$CP_TEST_DISPATCH_LOG" \
  && grep -F -q -- "agent --model composer-2.5-fast" "$CP_TEST_DISPATCH_LOG"; then
  ok "muxa dispatch is called with leased cwd, brief-file, default CMD"
else
  fail "muxa dispatch args ($(cat "$CP_TEST_DISPATCH_LOG"))"
fi
if git -C "$LEASE" symbolic-ref --short HEAD | grep -F -q job-ok; then
  ok "leased worktree is on the --br-id branch"
else
  fail "leased worktree branch is $(git -C "$LEASE" symbolic-ref --short HEAD 2>/dev/null || echo detached)"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert rows[0]["job"]=="job-ok"; assert rows[0]["branch"]=="job-ok"'; then
  ok "jobs add recorded worker/worktree/branch"
else
  fail "jobs add row missing"
fi
if grep -q 'return' "$CP_TEST_TH_LOG"; then
  fail "happy path does not return the lease"
else
  ok "happy path does not return the lease"
fi

# receipt unconfirmed is still success
reset_logs
# worktree is already on job-ok; create a fresh detached lease target
git -C "$CLONE" worktree add --detach -q "$TMP/leased2" >/dev/null
LEASE2="$(cd "$TMP/leased2" && pwd -P)"
export CP_TEST_LEASE="$LEASE2"
printf 'no token here\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-unconf --task-file "$TMP/task.txt" 2>"$TMP/err.un")" || {
  fail "unconfirmed dispatch (exit $? err=$(cat "$TMP/err.un"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"]=="unconfirmed"; assert o["state"]=="dispatched"'; then
  ok "receipt=unconfirmed with state=dispatched is success"
else
  fail "unconfirmed JSON (out=$out err=$(cat "$TMP/err.un"))"
fi

# --name is passed through; custom CMD after --
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased3" >/dev/null
LEASE3="$(cd "$TMP/leased3" && pwd -P)"
export CP_TEST_LEASE="$LEASE3"
printf 'Branch: job-name\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-name --name crisp-oak --task-file "$TMP/task.txt" -- \
  my-agent --model x >/dev/null 2>"$TMP/err.name" || true
if grep -F -q -- "--name crisp-oak" "$CP_TEST_DISPATCH_LOG" \
  && grep -F -q -- "my-agent --model x" "$CP_TEST_DISPATCH_LOG"; then
  ok "--name and custom CMD are passed to muxa dispatch"
else
  fail "--name/CMD args ($(cat "$CP_TEST_DISPATCH_LOG") err=$(cat "$TMP/err.name"))"
fi

# --template loads templates/brief-<TNAME>.md
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased4" >/dev/null
LEASE4="$(cd "$TMP/leased4" && pwd -P)"
export CP_TEST_LEASE="$LEASE4"
mkdir -p "$CP_HOME/templates"
cat > "$CP_HOME/templates/brief-research.md" <<'EOF'
Parent={{PARENT}} Branch={{BRANCH}} Id={{BR_ID}} Artifact={{ARTIFACT_PATH}}
{{TASK}}
EOF
printf 'Branch: job-tpl\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-tpl --template research --task-file "$TMP/task.txt" \
  >/dev/null 2>"$TMP/err.tpl" || true
if grep -F -q -- "Parent=test-parent" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "Branch=job-tpl" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "Id=job-tpl" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "Artifact=$CP_HOME/state/artifacts/job-tpl/report.md" "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- "do the work" "$CP_TEST_BRIEF_COPY"; then
  ok "--template substitutes the placeholder contract"
else
  fail "--template brief ($(cat "$CP_TEST_BRIEF_COPY" 2>/dev/null) err=$(cat "$TMP/err.tpl"))"
fi

# leftover placeholder is an error; lease returned
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased5" >/dev/null
LEASE5="$(cd "$TMP/leased5" && pwd -P)"
export CP_TEST_LEASE="$LEASE5"
printf '{{FOO}}\n{{PARENT}}\n' > "$CP_HOME/templates/brief-bad.md"
expect_rc_msg 1 "placeholder {{FOO}} left unsubstituted" \
  "unsubstituted placeholder is refused" \
  "$CP" dispatch --project demo --br-id job-ph --template bad --task-file "$TMP/task.txt"
if grep -q 'return --force' "$CP_TEST_TH_LOG"; then
  ok "placeholder failure returns the lease"
else
  fail "placeholder failure returns the lease (log=$(cat "$CP_TEST_TH_LOG"))"
fi

# missing template
reset_logs
expect_rc_msg 1 "template not at" "missing --template file is refused" \
  "$CP" dispatch --project demo --br-id job-notpl --template nope --task-file "$TMP/task.txt"

# check failure after lease → return and abort
reset_logs
OTHER="$TMP/other"
make_clone "$OTHER"
git init -q --bare "$TMP/other-origin.git"
git -C "$OTHER" remote add origin "$TMP/other-origin.git"
git -C "$OTHER" push -q -u origin main
git -C "$OTHER" remote set-head origin main
git -C "$OTHER" worktree add --detach -q "$TMP/foreign" >/dev/null
FOREIGN="$(cd "$TMP/foreign" && pwd -P)"
export CP_TEST_LEASE="$FOREIGN"
expect_rc_msg 1 "belongs to another repo" "check failure after lease is refused" \
  "$CP" dispatch --project demo --br-id job-chk --task-file "$TMP/task.txt"
if grep -q "return --force $FOREIGN" "$CP_TEST_TH_LOG"; then
  ok "check failure returns the leased path"
else
  fail "check failure returns the leased path (log=$(cat "$CP_TEST_TH_LOG"))"
fi
if grep -q 'dispatch' "$CP_TEST_DISPATCH_LOG"; then
  fail "check failure does not call muxa dispatch"
else
  ok "check failure does not call muxa dispatch"
fi

# cwd mismatch: dispatch succeeded, do not return the lease
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased6" >/dev/null
LEASE6="$(cd "$TMP/leased6" && pwd -P)"
export CP_TEST_LEASE="$LEASE6"
export CP_TEST_DISPATCH_CWD="/tmp/wrong-cwd"
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "do not retype paths" "dispatch cwd mismatch is refused" \
  "$CP" dispatch --project demo --br-id job-cwd --task-file "$TMP/task.txt"
if grep -q 'return' "$CP_TEST_TH_LOG"; then
  fail "cwd mismatch does not return the lease (worker may be live)"
else
  ok "cwd mismatch does not return the lease (worker may be live)"
fi
unset CP_TEST_DISPATCH_CWD

# missing origin → fetch fails, lease returned
reset_logs
NOORIG="$TMP/home2"
mkdir -p "$NOORIG/projects"
make_clone "$NOORIG/projects/demo"
git -C "$NOORIG/projects/demo" worktree add --detach -q "$TMP/leased-noo" >/dev/null
NOO="$(cd "$TMP/leased-noo" && pwd -P)"
expect_rc_msg 1 "git fetch origin failed" "fetch without origin is refused" \
  env CP_HOME="$NOORIG" CP_JOBS_FILE="$NOORIG/state/jobs.tsv" \
  BR_SHOW_CMD=true MUXA_WHOAMI=test-parent CP_TEST_LEASE="$NOO" \
  CP_TEST_TH_LOG="$TMP/th-noo.log" \
  "$CP" dispatch --project demo --br-id job-fetch --task-file "$TMP/task.txt"
if grep -q 'return --force' "$TMP/th-noo.log"; then
  ok "fetch failure returns the lease"
else
  fail "fetch failure returns the lease (log=$(cat "$TMP/th-noo.log"))"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
