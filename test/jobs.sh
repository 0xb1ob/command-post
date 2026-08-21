#!/usr/bin/env bash
# Unit tests for bin/cp jobs (runtime map only; not a live dispatch E2E).
# Run from the command-post repo: test/jobs.sh
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

expect_exit() {
  local want="$1" label="$2"
  shift 2
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq "$want" ]]; then
    ok "$label (exit $want)"
  else
    fail "$label (want exit $want, got $rc)"
  fi
}

expect_stdout() {
  local needle="$1" label="$2"
  shift 2
  local out
  out="$("$@")"
  if printf '%s\n' "$out" | grep -F -q -- "$needle"; then
    ok "$label"
  else
    fail "$label (stdout missing $(printf %q "$needle"); got: $out)"
  fi
}

expect_no_stdout() {
  local needle="$1" label="$2"
  shift 2
  local out
  out="$("$@")"
  if printf '%s\n' "$out" | grep -F -q -- "$needle"; then
    fail "$label (stdout unexpectedly has $(printf %q "$needle"))"
  else
    ok "$label"
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-jobs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
export BR_SHOW_CMD=true
mkdir -p "$CP_HOME" "$TMP/wt"
git -C "$TMP/wt" init -q
git -C "$TMP/wt" symbolic-ref HEAD refs/heads/feat/detect >/dev/null
WT="$(cd "$TMP/wt" && pwd -P)"

# add records worker, worktree, branch; list shows them
out="$("$CP" jobs add cp-one worker=swift-oak worktree="$TMP/wt" branch=feat/explicit)"
if printf '%s\n' "$out" | grep -q 'jobs add cp-one'; then
  ok "add logs the row"
else
  fail "add logs the row: $out"
fi
expect_stdout "cp-one" "list includes job id" "$CP" jobs list
expect_stdout "swift-oak" "list includes worker" "$CP" jobs list
expect_stdout "feat/explicit" "list includes passed branch" "$CP" jobs list
expect_stdout "$WT" "list includes worktree" "$CP" jobs list

# JSON is the parseable form
json="$("$CP" jobs list --json)"
if printf '%s\n' "$json" | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert rows[0]["job"]=="cp-one"; assert rows[0]["worker"]=="swift-oak"; assert rows[0]["branch"]=="feat/explicit"'; then
  ok "list --json is a JSON array of runtime rows"
else
  fail "list --json parse: $json"
fi

# duplicate add fails; set updates; done drops
expect_exit 1 "duplicate add refused" "$CP" jobs add cp-one worker=other worktree="$TMP/wt" branch=x
"$CP" jobs set cp-one worker=crisp-oak >/dev/null
expect_stdout "crisp-oak" "set updates worker" "$CP" jobs list
"$CP" jobs "done" cp-one >/dev/null
expect_no_stdout "cp-one" "done drops the runtime row" "$CP" jobs list
if "$CP" jobs list --json | python3 -c 'import json,sys; assert json.load(sys.stdin)==[]'; then
  ok "list --json is [] after done"
else
  fail "list --json empty after done"
fi

# branch from git when omitted
"$CP" jobs add cp-two worker=quiet-fox worktree="$TMP/wt" >/dev/null
expect_stdout "feat/detect" "add reads branch from the worktree" "$CP" jobs list
"$CP" jobs "done" cp-two >/dev/null

# durable fields are refused (they live on br)
expect_exit 1 "add rejects kind=" "$CP" jobs add cp-x worker=a worktree="$TMP/wt" kind=ship
expect_exit 1 "add rejects delivery=" "$CP" jobs add cp-x worker=a worktree="$TMP/wt" delivery=pr
"$CP" jobs add cp-keep worker=a worktree="$TMP/wt" >/dev/null
expect_exit 1 "set rejects status=" "$CP" jobs set cp-keep status=done
expect_exit 1 "set rejects pr=" "$CP" jobs set cp-keep pr=https://example.test/pull/1
expect_exit 1 "set rejects note=" "$CP" jobs set cp-keep note=cp-keep
expect_exit 1 "done rejects pr=" "$CP" jobs "done" cp-keep pr=https://example.test/pull/1
expect_stdout "cp-keep" "refused done pr= leaves the row" "$CP" jobs list

# missing runtime fields / unknown id / usage
expect_exit 2 "add without worker is usage" "$CP" jobs add cp-y worktree="$TMP/wt"
expect_exit 2 "add without worktree is usage" "$CP" jobs add cp-y worker=a
expect_exit 1 "set unknown id fails" "$CP" jobs set cp-missing worker=a
expect_exit 1 "done unknown id fails" "$CP" jobs "done" cp-missing
expect_exit 2 "jobs without subcommand is usage" "$CP" jobs
expect_exit 2 "unknown jobs subcommand is usage" "$CP" jobs frob

# br miss is fail-closed
export BR_SHOW_CMD=false
expect_exit 1 "add fails when br show fails" "$CP" jobs add cp-nope worker=a worktree="$TMP/wt"
export BR_SHOW_CMD=true

# whitespace in id refused
expect_exit 1 "whitespace id refused" "$CP" jobs add "cp foo" worker=a worktree="$TMP/wt"

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
