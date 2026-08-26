#!/usr/bin/env bash
# Unit tests for bin/cp teardown. muxa and treehouse are PATH shims; git
# runs against temp clones. Never touches the live broker, HOME .beads,
# or real worktrees. Run: test/teardown.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-teardown.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
export BR_SHOW_CMD=true
export MUXA_WHOAMI=test-parent
export CP_TEST_WHO="$TMP/who.json"
export CP_TEST_TH_LOG="$TMP/treehouse.log"
export CP_TEST_KILL_LOG="$TMP/kill.log"
mkdir -p "$CP_HOME" "$TMP/shim"
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_KILL_LOG"

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

make_pushed_wt() {
  local dest="$1" branch="$2"
  mkdir -p "$dest"
  git -C "$dest" init -q -b main
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  git init -q --bare "$dest.origin.git"
  git -C "$dest" remote add origin "$dest.origin.git"
  git -C "$dest" checkout -q -b "$branch"
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m work
  git -C "$dest" push -q -u origin "$branch"
}

# Mirror create_job_branch: push default, then --no-track cut (never-ready).
make_never_ready_wt() {
  local dest="$1" branch="$2" base="${3:-main}"
  mkdir -p "$dest"
  git -C "$dest" init -q -b "$base"
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
  git init -q --bare "$dest.origin.git"
  git -C "$dest" remote add origin "$dest.origin.git"
  git -C "$dest" push -q origin "$base"
  git -C "$dest" switch --no-track -q -c "$branch" "origin/$base"
}

# unknown id
expect_rc_msg 1 "no runtime row" "unknown job id is refused" \
  "$CP" teardown missing-id

# dirty: refuse, keep lease, keep jobs row
WT_DIRTY="$TMP/wt-dirty"
make_pushed_wt "$WT_DIRTY" feat-dirty
WT_DIRTY="$(cd "$WT_DIRTY" && pwd -P)"
printf 'dirt\n' > "$WT_DIRTY/file.txt"
"$CP" jobs add job-dirty worker=swift-oak worktree="$WT_DIRTY" branch=feat-dirty >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "dirty worktree $WT_DIRTY" "dirty worktree refuses teardown" \
  "$CP" teardown job-dirty
expect_rc_msg 1 "keep the lease" "dirty refusal names keep-the-lease" \
  "$CP" teardown job-dirty
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "dirty teardown does not return the lease"
else
  ok "dirty teardown does not return the lease"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert any(r["job"]=="job-dirty" for r in rows)'; then
  ok "dirty teardown leaves the jobs row"
else
  fail "dirty teardown leaves the jobs row"
fi

# unpushed: no upstream and not on origin
WT_UNPUSH="$TMP/wt-unpush"
mkdir -p "$WT_UNPUSH"
git -C "$WT_UNPUSH" init -q -b feat-unpush
git -C "$WT_UNPUSH" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
WT_UNPUSH="$(cd "$WT_UNPUSH" && pwd -P)"
"$CP" jobs add job-unpush worker=quiet-fox worktree="$WT_UNPUSH" branch=feat-unpush >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_UNPUSH" "unpushed branch refuses teardown" \
  "$CP" teardown job-unpush
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "unpushed teardown does not return the lease"
else
  ok "unpushed teardown does not return the lease"
fi

# never-ready: clean --no-track cut from origin/main, no origin/$branch, no @{u}
WT_NEVER="$TMP/wt-never"
make_never_ready_wt "$WT_NEVER" feat-never
WT_NEVER="$(cd "$WT_NEVER" && pwd -P)"
"$CP" jobs add job-never worker=cold-fox worktree="$WT_NEVER" branch=feat-never >/dev/null
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_KILL_LOG"
if "$CP" teardown job-never >/dev/null 2>"$TMP/err.never"; then
  ok "never-ready teardown exits 0"
else
  fail "never-ready teardown exits 0 (err=$(cat "$TMP/err.never"))"
fi
if grep -q "return --force $WT_NEVER" "$CP_TEST_TH_LOG"; then
  ok "never-ready teardown returns the lease"
else
  fail "never-ready teardown returns the lease (log=$(cat "$CP_TEST_TH_LOG"))"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert not any(r["job"]=="job-never" for r in rows)'; then
  ok "never-ready teardown drops the jobs row"
else
  fail "never-ready teardown drops the jobs row"
fi

# never-ready refuse: extra commit on job branch
WT_NEVER_UNPUSH="$TMP/wt-never-unpush"
make_never_ready_wt "$WT_NEVER_UNPUSH" feat-never-unpush
git -C "$WT_NEVER_UNPUSH" -c user.email=t@t -c user.name=t commit --allow-empty -q -m extra
WT_NEVER_UNPUSH="$(cd "$WT_NEVER_UNPUSH" && pwd -P)"
"$CP" jobs add job-never-unpush worker=warm-fox worktree="$WT_NEVER_UNPUSH" branch=feat-never-unpush >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_NEVER_UNPUSH" "never-ready with extra commit refuses teardown" \
  "$CP" teardown job-never-unpush
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "never-ready extra commit does not return the lease"
else
  ok "never-ready extra commit does not return the lease"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert any(r["job"]=="job-never-unpush" for r in rows)'; then
  ok "never-ready extra commit leaves the jobs row"
else
  fail "never-ready extra commit leaves the jobs row"
fi

# refuse pushed-then-reset: origin/$branch exists and mismatches
WT_RESET="$TMP/wt-reset"
make_never_ready_wt "$WT_RESET" feat-reset
git -C "$WT_RESET" -c user.email=t@t -c user.name=t commit --allow-empty -q -m work
git -C "$WT_RESET" push -q -u origin feat-reset
git -C "$WT_RESET" reset --hard -q origin/main
WT_RESET="$(cd "$WT_RESET" && pwd -P)"
"$CP" jobs add job-reset worker=reset-fox worktree="$WT_RESET" branch=feat-reset >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_RESET" "pushed-then-reset refuses teardown" \
  "$CP" teardown job-reset
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "pushed-then-reset does not return the lease"
else
  ok "pushed-then-reset does not return the lease"
fi

# refuse detached HEAD at default while branch has unique commits
WT_DETACH="$TMP/wt-detach"
make_never_ready_wt "$WT_DETACH" feat-detach
git -C "$WT_DETACH" -c user.email=t@t -c user.name=t commit --allow-empty -q -m extra
git -C "$WT_DETACH" checkout --detach -q origin/main
WT_DETACH="$(cd "$WT_DETACH" && pwd -P)"
"$CP" jobs add job-detach worker=detach-fox worktree="$WT_DETACH" branch=feat-detach >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_DETACH" "detached at default with branch commits refuses teardown" \
  "$CP" teardown job-detach
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "detached default does not return the lease"
else
  ok "detached default does not return the lease"
fi

# refuse tip equal to other ref, not origin/main
WT_OTHER="$TMP/wt-other"
make_never_ready_wt "$WT_OTHER" feat-other
git -C "$WT_OTHER" -c user.email=t@t -c user.name=t checkout -q -b develop
git -C "$WT_OTHER" -c user.email=t@t -c user.name=t commit --allow-empty -q -m on-develop
git -C "$WT_OTHER" push -q origin develop
git -C "$WT_OTHER" switch --no-track -q -c feat-other-tip origin/develop
WT_OTHER="$(cd "$WT_OTHER" && pwd -P)"
"$CP" jobs add job-other worker=other-fox worktree="$WT_OTHER" branch=feat-other-tip >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_OTHER" "tip at non-default origin ref refuses teardown" \
  "$CP" teardown job-other
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "non-default tip does not return the lease"
else
  ok "non-default tip does not return the lease"
fi

# origin/HEAD -> master: never-ready cut from origin/master
WT_MASTER="$TMP/wt-master"
make_never_ready_wt "$WT_MASTER" feat-master master
git -C "$WT_MASTER.origin.git" symbolic-ref HEAD refs/heads/master
git -C "$WT_MASTER" fetch -q origin
WT_MASTER="$(cd "$WT_MASTER" && pwd -P)"
"$CP" jobs add job-master worker=master-fox worktree="$WT_MASTER" branch=feat-master >/dev/null
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
if "$CP" teardown job-master >/dev/null 2>"$TMP/err.master"; then
  ok "never-ready with origin/HEAD=master exits 0"
else
  fail "never-ready with origin/HEAD=master (err=$(cat "$TMP/err.master"))"
fi

# happy path: clean + pushed, return from HOME, kill if present, jobs done
WT_OK="$TMP/wt-ok"
make_pushed_wt "$WT_OK" feat-ok
WT_OK="$(cd "$WT_OK" && pwd -P)"
"$CP" jobs add job-ok worker=crisp-oak worktree="$WT_OK" branch=feat-ok >/dev/null
cat > "$CP_TEST_WHO" <<EOF
[{"name":"crisp-oak","id":"abc","parent":null,"kind":"cursor","state":"idle","pane":"%1","session":null,"cwd":"$WT_OK"}]
EOF
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_KILL_LOG"
if "$CP" teardown job-ok >/dev/null 2>"$TMP/err.ok"; then
  ok "clean pushed teardown exits 0"
else
  fail "clean pushed teardown exits 0 (err=$(cat "$TMP/err.ok"))"
fi
if grep -F -q -- "cwd=$CP_HOME args=return --force $WT_OK" "$CP_TEST_TH_LOG" \
  || grep -F -q -- "return --force $WT_OK" "$CP_TEST_TH_LOG"; then
  ok "treehouse return --force runs from command-post HOME"
else
  fail "treehouse return from HOME (log=$(cat "$CP_TEST_TH_LOG"))"
fi
home_abs="$(cd "$CP_HOME" && pwd -P)"
if grep -F "cwd=$home_abs" "$CP_TEST_TH_LOG" >/dev/null; then
  ok "treehouse cwd is CP_HOME, not the worktree"
else
  fail "treehouse cwd is CP_HOME (log=$(cat "$CP_TEST_TH_LOG"))"
fi
if grep -F -q -- "crisp-oak" "$CP_TEST_KILL_LOG"; then
  ok "muxa kill is called when the worker is still on the roster"
else
  fail "muxa kill when present (log=$(cat "$CP_TEST_KILL_LOG"))"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert not any(r["job"]=="job-ok" for r in rows)'; then
  ok "teardown drops the jobs row (does not close br)"
else
  fail "teardown drops the jobs row"
fi

# already-gone worker: skip kill, still return + jobs done
WT_GONE="$TMP/wt-gone"
make_pushed_wt "$WT_GONE" feat-gone
WT_GONE="$(cd "$WT_GONE" && pwd -P)"
"$CP" jobs add job-gone worker=gone-fox worktree="$WT_GONE" branch=feat-gone >/dev/null
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_KILL_LOG"
if "$CP" teardown job-gone >/dev/null 2>"$TMP/err.gone"; then
  ok "already-gone worker teardown exits 0"
else
  fail "already-gone worker teardown (err=$(cat "$TMP/err.gone"))"
fi
if [[ -s "$CP_TEST_KILL_LOG" ]]; then
  fail "already-gone worker does not call muxa kill"
else
  ok "already-gone worker does not call muxa kill"
fi
if grep -q "return --force $WT_GONE" "$CP_TEST_TH_LOG"; then
  ok "already-gone worker still returns the lease"
else
  fail "already-gone worker still returns the lease (log=$(cat "$CP_TEST_TH_LOG"))"
fi

# artifact dir under HOME is removed on successful teardown (mirrored report.md only)
WT_ART="$TMP/wt-art"
make_pushed_wt "$WT_ART" feat-art
WT_ART="$(cd "$WT_ART" && pwd -P)"
"$CP" jobs add job-art worker=art-owl worktree="$WT_ART" branch=feat-art >/dev/null
mkdir -p "$CP_HOME/state/artifacts/job-art"
printf 'findings\n' > "$CP_HOME/state/artifacts/job-art/report.md"
printf '[]\n' > "$CP_TEST_WHO"
if "$CP" teardown job-art >/dev/null 2>"$TMP/err.art" \
  && [[ ! -d "$CP_HOME/state/artifacts/job-art" ]]; then
  ok "teardown removes state/artifacts/<id> when only report.md is present"
else
  fail "teardown removes state/artifacts/<id> when only report.md is present (err=$(cat "$TMP/err.art"))"
fi

# unmirrored companion files: refuse teardown, keep lease and extras
WT_ARTX="$TMP/wt-artx"
make_pushed_wt "$WT_ARTX" feat-artx
WT_ARTX="$(cd "$WT_ARTX" && pwd -P)"
"$CP" jobs add job-artx worker=art-lynx worktree="$WT_ARTX" branch=feat-artx >/dev/null
mkdir -p "$CP_HOME/state/artifacts/job-artx"
printf 'findings\n' > "$CP_HOME/state/artifacts/job-artx/report.md"
printf 'extra row\n' > "$CP_HOME/state/artifacts/job-artx/summary.tsv"
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "summary.tsv" "unmirrored artifact file refuses teardown" \
  "$CP" teardown job-artx
expect_rc_msg 1 "keep the lease" "unmirrored artifact refusal names keep-the-lease" \
  "$CP" teardown job-artx
if grep -q return "$CP_TEST_TH_LOG"; then
  fail "unmirrored artifact teardown does not return the lease"
else
  ok "unmirrored artifact teardown does not return the lease"
fi
if "$CP" jobs list --json | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert any(r["job"]=="job-artx" for r in rows)'; then
  ok "unmirrored artifact teardown leaves the jobs row"
else
  fail "unmirrored artifact teardown leaves the jobs row"
fi
if [[ -f "$CP_HOME/state/artifacts/job-artx/summary.tsv" ]]; then
  ok "unmirrored artifact teardown preserves companion files"
else
  fail "unmirrored artifact teardown preserves companion files"
fi

# research: never-ready branch, HEAD on main — teardown via --research
WT_RESEARCH="$TMP/wt-research"
make_never_ready_wt "$WT_RESEARCH" feat-research
git -C "$WT_RESEARCH" switch -q main
WT_RESEARCH="$(cd "$WT_RESEARCH" && pwd -P)"
"$CP" jobs add job-research worker=research-fox worktree="$WT_RESEARCH" branch=feat-research >/dev/null
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
: > "$CP_TEST_KILL_LOG"
if "$CP" teardown --research job-research >/dev/null 2>"$TMP/err.research"; then
  ok "research teardown (--research, HEAD on main) exits 0"
else
  fail "research teardown (--research, HEAD on main) exits 0 (err=$(cat "$TMP/err.research"))"
fi
if grep -q "return --force $WT_RESEARCH" "$CP_TEST_TH_LOG"; then
  ok "research teardown returns the lease"
else
  fail "research teardown returns the lease (log=$(cat "$CP_TEST_TH_LOG"))"
fi

# research via br kind:research label stub
cat > "$TMP/br-show-stub" <<'EOF'
#!/usr/bin/env bash
id="${@: -1}"
case "$id" in
  job-research-label)
    printf '[{"labels":["kind:research","project:test"]}]\n'
    exit 0
    ;;
esac
exit 1
EOF
chmod +x "$TMP/br-show-stub"
WT_RESEARCH_LABEL="$TMP/wt-research-label"
make_never_ready_wt "$WT_RESEARCH_LABEL" feat-research-label
WT_RESEARCH_LABEL="$(cd "$WT_RESEARCH_LABEL" && pwd -P)"
"$CP" jobs add job-research-label worker=research-owl worktree="$WT_RESEARCH_LABEL" branch=feat-research-label >/dev/null
printf '[]\n' > "$CP_TEST_WHO"
: > "$CP_TEST_TH_LOG"
if BR_SHOW_CMD="$TMP/br-show-stub" "$CP" teardown job-research-label >/dev/null 2>"$TMP/err.research-label"; then
  ok "research teardown (kind:research label) exits 0"
else
  fail "research teardown (kind:research label) exits 0 (err=$(cat "$TMP/err.research-label"))"
fi

# research with unpushed commit on job branch still fails
WT_RESEARCH_BAD="$TMP/wt-research-bad"
make_never_ready_wt "$WT_RESEARCH_BAD" feat-research-bad
git -C "$WT_RESEARCH_BAD" -c user.email=t@t -c user.name=t commit --allow-empty -q -m extra
WT_RESEARCH_BAD="$(cd "$WT_RESEARCH_BAD" && pwd -P)"
"$CP" jobs add job-research-bad worker=research-bad worktree="$WT_RESEARCH_BAD" branch=feat-research-bad >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed commit(s)" "research with local commits refuses teardown" \
  "$CP" teardown --research job-research-bad

# ship unpushed unchanged (explicit regression)
WT_SHIP="$TMP/wt-ship-unpush"
mkdir -p "$WT_SHIP"
git -C "$WT_SHIP" init -q -b feat-ship-unpush
git -C "$WT_SHIP" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
WT_SHIP="$(cd "$WT_SHIP" && pwd -P)"
"$CP" jobs add job-ship-unpush worker=ship-fox worktree="$WT_SHIP" branch=feat-ship-unpush >/dev/null
: > "$CP_TEST_TH_LOG"
expect_rc_msg 1 "unpushed $WT_SHIP" "ship unpushed branch still refuses teardown" \
  "$CP" teardown job-ship-unpush

# help
expect_rc_msg 2 "Does not close the br issue" "teardown help says it does not close br" \
  "$CP" teardown --help

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
