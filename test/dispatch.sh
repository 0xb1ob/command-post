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

make_worker_shim() {
  local name="$1"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/shim/$name"
  chmod +x "$TMP/shim/$name"
}

make_worker_shim agent

ensure_host_utils() {
  mkdir -p "$TMP/host"
  local c p
  for c in rm mkdir mktemp git bash awk sed grep chmod printf python3; do
    p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$TMP/host/$c"
  done
}

worker_host_path() {
  printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$d" in
      "$TMP/shim"|"$TMP/host") continue ;;
    esac
    [[ -x "$d/agent" || -x "$d/claude" || -x "$d/cursor-agent" ]] && continue
    printf '%s:' "$d"
  done | sed 's/:$//'
}

set_test_path() {
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(worker_host_path)"
}

ensure_host_utils
set_test_path

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

# missing worker CLI: no lease, no dispatch, exit 2
reset_logs
rm -f "$TMP/shim/agent" "$TMP/shim/claude" "$TMP/shim/cursor-agent"
set_test_path
expect_rc_msg 2 "worker CLI agent not on PATH" "missing agent exits 2 before lease" \
  "$CP" dispatch --project demo --br-id job-nocli --task-file "$TMP/task.txt"
set_test_path
expect_rc_msg 2 "bin/cp doctor" "missing agent names bin/cp doctor" \
  "$CP" dispatch --project demo --br-id job-nocli2 --task-file "$TMP/task.txt"
if grep -q 'get' "$CP_TEST_TH_LOG"; then
  fail "missing agent does not call treehouse get"
else
  ok "missing agent does not call treehouse get"
fi
if grep -q 'dispatch' "$CP_TEST_DISPATCH_LOG"; then
  fail "missing agent does not call muxa dispatch"
else
  ok "missing agent does not call muxa dispatch"
fi
make_worker_shim agent
set_test_path

# claude only on PATH with explicit override succeeds
reset_logs
rm -f "$TMP/shim/agent"
make_worker_shim claude
set_test_path
git -C "$CLONE" worktree add --detach -q "$TMP/leased-cl" >/dev/null
LEASE_CL="$(cd "$TMP/leased-cl" && pwd -P)"
export CP_TEST_LEASE="$LEASE_CL"
printf 'Branch: job-cl\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-cl --task-file "$TMP/task.txt" -- \
  claude --model x >/dev/null 2>"$TMP/err.cl" || {
  fail "claude override dispatch (err=$(cat "$TMP/err.cl"))"
}
if grep -F -q -- "claude --model x" "$CP_TEST_DISPATCH_LOG"; then
  ok "claude override is passed to muxa dispatch"
else
  fail "claude override args ($(cat "$CP_TEST_DISPATCH_LOG"))"
fi
rm -f "$TMP/shim/claude"
make_worker_shim agent
set_test_path

# claude only, no override: still exit 2 (no silent fallback to claude)
reset_logs
rm -f "$TMP/shim/agent"
make_worker_shim claude
set_test_path
expect_rc_msg 2 "worker CLI agent not on PATH" "claude on PATH without override still requires routed agent" \
  "$CP" dispatch --project demo --br-id job-nofb --task-file "$TMP/task.txt"
if grep -q 'get' "$CP_TEST_TH_LOG"; then
  fail "no-fallback does not lease"
else
  ok "no silent fallback to claude (no lease)"
fi
make_worker_shim agent
set_test_path

# routing.tsv researcher row with --template research
reset_logs
mkdir -p "$CP_HOME/data" "$CP_HOME/templates"
cat > "$CP_HOME/templates/brief-research.md" <<'EOF'
Parent={{PARENT}} Branch={{BRANCH}} Id={{BR_ID}} Artifact={{ARTIFACT_PATH}}
{{TASK}}
EOF
cat > "$CP_HOME/data/routing.tsv" <<'EOF'
researcher	claude	--model	grok
implementer	agent	--model	composer-2.5-fast
gate-reviewer	agent	--model	composer-2.5-fast
EOF
rm -f "$TMP/shim/agent"
make_worker_shim claude
set_test_path
git -C "$CLONE" worktree add --detach -q "$TMP/leased-rtr" >/dev/null
LEASE_RTR="$(cd "$TMP/leased-rtr" && pwd -P)"
export CP_TEST_LEASE="$LEASE_RTR"
printf 'Branch: job-rtr\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-rtr --template research --task-file "$TMP/task.txt" \
  >/dev/null 2>"$TMP/err.rtr" || fail "routing researcher dispatch (err=$(cat "$TMP/err.rtr"))"
if grep -F -q -- "claude --model grok" "$CP_TEST_DISPATCH_LOG"; then
  ok "routing.tsv researcher row used with --template research"
else
  fail "routing researcher CMD ($(cat "$CP_TEST_DISPATCH_LOG"))"
fi
rm -f "$CP_HOME/data/routing.tsv"
make_worker_shim agent
set_test_path

# unknown override CLI fails closed
reset_logs
expect_rc_msg 2 "not in share/clis.tsv" "my-agent override fails (not in registry)" \
  "$CP" dispatch --project demo --br-id job-badcli --task-file "$TMP/task.txt" -- \
  my-agent --model x

# happy path: lease captured, branch created, jobs recorded, receipt confirmed
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-happy" >/dev/null
LEASE="$(cd "$TMP/leased-happy" && pwd -P)"
export CP_TEST_LEASE="$LEASE"
set_test_path
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

# receipt unconfirmed is still success (tail has neither Branch: nor bare branch)
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

# cursor-style tail: pasted brief collapsed; footer shows bare branch
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-cur" >/dev/null
LEASE_CUR="$(cd "$TMP/leased-cur" && pwd -P)"
export CP_TEST_LEASE="$LEASE_CUR"
printf '[Pasted text]\n~/path · job-cursor\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-cursor --task-file "$TMP/task.txt" 2>"$TMP/err.cur")" || {
  fail "cursor-footer dispatch (exit $? err=$(cat "$TMP/err.cur"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"]=="confirmed"; assert o["state"]=="dispatched"'; then
  ok "cursor-style footer branch confirms receipt"
else
  fail "cursor-footer JSON (out=$out err=$(cat "$TMP/err.cur"))"
fi

# claude false positive: footer renders cwd+branch regardless of receipt.
# The bare-branch match that works for cursor must NOT fire for kind=claude.
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-claude-fp" >/dev/null
LEASE_CLAUDE_FP="$(cd "$TMP/leased-claude-fp" && pwd -P)"
export CP_TEST_LEASE="$LEASE_CLAUDE_FP"
cat > "$CP_TEST_WHO" <<EOF
[{"name":"swift-oak","id":"abc","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/tmp/cp-test-not-a-worktree"}]
EOF
printf 'pane/leased-claude-fp (job-claude-fp) | Opus 5 | Context: 0.0%%\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-claude-fp --task-file "$TMP/task.txt" 2>"$TMP/err.cfp")" || {
  fail "claude false-positive dispatch (exit $? err=$(cat "$TMP/err.cfp"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"] != "confirmed", o'; then
  ok "claude footer-only branch text does not confirm receipt (false positive guard)"
else
  fail "claude false-positive JSON (out=$out err=$(cat "$TMP/err.cfp"))"
fi
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"] == "unknown", o'; then
  ok "claude zero-context footer reads receipt=unknown, not unconfirmed"
else
  fail "claude false-positive receipt value (out=$out)"
fi

# claude confirmed: nonzero footer Context% means the brief was consumed.
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-claude-ok" >/dev/null
LEASE_CLAUDE_OK="$(cd "$TMP/leased-claude-ok" && pwd -P)"
export CP_TEST_LEASE="$LEASE_CLAUDE_OK"
cat > "$CP_TEST_WHO" <<EOF
[{"name":"swift-oak","id":"abc","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/tmp/cp-test-not-a-worktree"}]
EOF
printf 'pane/leased-claude-ok (job-claude-ok) | Opus 5 | Context: 4.2%%\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-claude-ok --task-file "$TMP/task.txt" 2>"$TMP/err.cok")" || {
  fail "claude confirmed dispatch (exit $? err=$(cat "$TMP/err.cok"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"]=="confirmed"'; then
  ok "claude nonzero footer Context confirms receipt"
else
  fail "claude confirmed JSON (out=$out err=$(cat "$TMP/err.cok"))"
fi

# claude too-early: no footer drawn yet (boot in progress) is NOT reported
# as not-received — it is a distinct unknown state, never unconfirmed.
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-claude-boot" >/dev/null
LEASE_CLAUDE_BOOT="$(cd "$TMP/leased-claude-boot" && pwd -P)"
export CP_TEST_LEASE="$LEASE_CLAUDE_BOOT"
cat > "$CP_TEST_WHO" <<EOF
[{"name":"swift-oak","id":"abc","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/tmp/cp-test-not-a-worktree"}]
EOF
printf '\n' > "$CP_TEST_TAIL"
out="$("$CP" dispatch --project demo --br-id job-claude-boot --task-file "$TMP/task.txt" 2>"$TMP/err.cboot")" || {
  fail "claude too-early dispatch (exit $? err=$(cat "$TMP/err.cboot"))"
  out=""
}
if printf '%s\n' "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin); assert o["receipt"]=="unknown"; assert o["state"]=="dispatched"'; then
  ok "claude pane with no footer yet reads receipt=unknown (too-early, not not-received)"
else
  fail "claude too-early JSON (out=$out err=$(cat "$TMP/err.cboot"))"
fi

# --name is passed through; supported custom CMD after --
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased3" >/dev/null
LEASE3="$(cd "$TMP/leased3" && pwd -P)"
export CP_TEST_LEASE="$LEASE3"
printf 'Branch: job-name\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-name --name crisp-oak --task-file "$TMP/task.txt" -- \
  agent --model x >/dev/null 2>"$TMP/err.name" || true
if grep -F -q -- "--name crisp-oak" "$CP_TEST_DISPATCH_LOG" \
  && grep -F -q -- "agent --model x" "$CP_TEST_DISPATCH_LOG"; then
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

# task body with JSX-style {{ }} survives verbatim (not mistaken for placeholders)
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-jsx" >/dev/null
LEASE_JSX="$(cd "$TMP/leased-jsx" && pwd -P)"
export CP_TEST_LEASE="$LEASE_JSX"
cat > "$TMP/task-jsx.txt" <<'EOF'
Fix the button style={{ fontSize: 12 }} and also {{ margin: 0 }}.
EOF
printf 'Branch: job-jsx\n' > "$CP_TEST_TAIL"
"$CP" dispatch --project demo --br-id job-jsx --task-file "$TMP/task-jsx.txt" \
  >/dev/null 2>"$TMP/err.jsx" || {
  fail "dispatch with JSX-style task body (exit $? err=$(cat "$TMP/err.jsx"))"
}
if grep -F -q -- 'style={{ fontSize: 12 }}' "$CP_TEST_BRIEF_COPY" \
  && grep -F -q -- '{{ margin: 0 }}' "$CP_TEST_BRIEF_COPY"; then
  ok "task body {{ }} sequences pass through byte-identical"
else
  fail "JSX-style task body in brief ($(cat "$CP_TEST_BRIEF_COPY" 2>/dev/null) err=$(cat "$TMP/err.jsx"))"
fi

# unsubstituted known token in template still fails (spaces break substitution)
reset_logs
git -C "$CLONE" worktree add --detach -q "$TMP/leased-br" >/dev/null
LEASE_BR="$(cd "$TMP/leased-br" && pwd -P)"
export CP_TEST_LEASE="$LEASE_BR"
printf 'Branch: {{ BRANCH }}\n{{TASK}}\n' > "$CP_HOME/templates/brief-nobranch.md"
expect_rc_msg 1 "placeholder {{ BRANCH }} left unsubstituted" \
  "unsubstituted known token in template is refused" \
  "$CP" dispatch --project demo --br-id job-nobranch --template nobranch --task-file "$TMP/task.txt"

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
