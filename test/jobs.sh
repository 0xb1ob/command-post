#!/usr/bin/env bash
# Unit tests for bin/cmdp jobs (runtime map only; not a live dispatch E2E).
# Run from the command-post repo: test/jobs.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$ROOT/bin/cmdp"
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
out="$("$CP" jobs add cp-one worker=swift-oak worktree="$TMP/wt" branch=feat/explicit 2>&1)"
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
if printf '%s\n' "$json" | python3 -c 'import json,sys,re; rows=json.load(sys.stdin); r=rows[0]; assert r["job"]=="cp-one"; assert r["worker"]=="swift-oak"; assert r["branch"]=="feat/explicit"; assert "dispatched_at" in r; assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", r["dispatched_at"])'; then
  ok "list --json is a JSON array of runtime rows with dispatched_at"
else
  fail "list --json parse: $json"
fi

# legacy 4-column rows parse without dispatched_at
cat > "$CP_JOBS_FILE" <<EOF
#job	worker	worktree	branch
legacy-one	old-worker	$WT	legacy-branch
EOF
legacy_json="$("$CP" jobs list --json)"
if printf '%s\n' "$legacy_json" | python3 -c 'import json,sys; rows=json.load(sys.stdin); assert rows[0]["job"]=="legacy-one"; assert "dispatched_at" not in rows[0]'; then
  ok "list --json omits dispatched_at for legacy 4-column rows"
else
  fail "legacy list --json parse: $legacy_json"
fi

# mixed legacy + stamped rows in one file
cat > "$CP_JOBS_FILE" <<EOF
#job	worker	worktree	branch
legacy-two	old-worker	$WT	legacy-two
stamped-one	new-worker	$WT	stamped-branch	2026-08-24T12:00:00Z
held-one	held-worker	$WT	held-branch	2026-08-24T10:00:00Z	2026-08-24T11:00:00Z
EOF
mixed_json="$("$CP" jobs list --json)"
if printf '%s\n' "$mixed_json" | python3 -c '
import json, sys
rows = {r["job"]: r for r in json.load(sys.stdin)}
assert "dispatched_at" not in rows["legacy-two"]
assert "reported_at" not in rows["legacy-two"]
assert rows["stamped-one"]["dispatched_at"] == "2026-08-24T12:00:00Z"
assert "reported_at" not in rows["stamped-one"]
assert rows["held-one"]["dispatched_at"] == "2026-08-24T10:00:00Z"
assert rows["held-one"]["reported_at"] == "2026-08-24T11:00:00Z"
'; then
  ok "list --json parses mixed legacy, stamped, and reported rows"
else
  fail "mixed list --json parse: $mixed_json"
fi

# origin column: optional trailing field; legacy rows omit it
cat > "$CP_JOBS_FILE" <<EOF
#job	worker	worktree	branch
legacy-origin	old-worker	$WT	legacy-origin
stamped-origin	new-worker	$WT	stamped-branch	2026-08-24T12:00:00Z		origin-a
EOF
origin_json="$("$CP" jobs list --json)"
if printf '%s\n' "$origin_json" | python3 -c '
import json, sys
rows = {r["job"]: r for r in json.load(sys.stdin)}
assert "origin" not in rows["legacy-origin"]
assert rows["stamped-origin"]["origin"] == "origin-a"
assert rows["stamped-origin"]["dispatched_at"] == "2026-08-24T12:00:00Z"
'; then
  ok "list --json parses origin without backfill on legacy rows"
else
  fail "origin list --json parse: $origin_json"
fi

"$CP" jobs add cp-origin worker=swift-oak worktree="$WT" branch=feat/explicit origin=slack-thread-1 >/dev/null
explicit_json="$("$CP" jobs list --json | python3 -c 'import json,sys; print(json.dumps(next(r for r in json.load(sys.stdin) if r["job"]=="cp-origin")))')"
if printf '%s\n' "$explicit_json" | python3 -c 'import json,sys; r=json.load(sys.stdin); assert r["origin"]=="slack-thread-1"'; then
  ok "jobs add accepts origin= and list --json includes it"
else
  fail "jobs add origin=: $explicit_json"
fi

# fresh cp-one row for downstream duplicate/set/done tests
rm -f "$CP_JOBS_FILE"
"$CP" jobs add cp-one worker=swift-oak worktree="$TMP/wt" branch=feat/explicit >/dev/null

# duplicate add fails; set updates; done drops
expect_exit 1 "duplicate add refused" "$CP" jobs add cp-one worker=other worktree="$TMP/wt" branch=x
"$CP" jobs set cp-one worker=crisp-oak >/dev/null
expect_stdout "crisp-oak" "set updates worker" "$CP" jobs list
# set preserves dispatched_at; reported stamps reported_at once
stamp_before="$("$CP" jobs list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("dispatched_at",""))')"
"$CP" jobs set cp-one branch=feat/updated >/dev/null
stamp_after="$("$CP" jobs list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("dispatched_at",""))')"
if [[ -n "$stamp_before" && "$stamp_before" == "$stamp_after" ]]; then
  ok "set preserves dispatched_at"
else
  fail "set preserves dispatched_at (before=$stamp_before after=$stamp_after)"
fi
reported_out="$("$CP" jobs reported cp-one 2>&1)"
reported_json="$("$CP" jobs list --json)"
if printf '%s\n' "$reported_json" | python3 -c '
import json, sys, re
r = json.load(sys.stdin)[0]
assert r["job"] == "cp-one"
assert "reported_at" in r
assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", r["reported_at"])
'; then
  ok "reported stamps reported_at"
else
  fail "reported stamps reported_at: $reported_json"
fi
reported_once="$(printf '%s\n' "$reported_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["reported_at"])')"
if printf '%s\n' "$reported_out" | grep -F -q "reported_at=$reported_once"; then
  ok "reported confirmation echoes first stamp"
else
  fail "reported confirmation echoes first stamp (stdout=$reported_out stamp=$reported_once)"
fi
reported_again_out="$("$CP" jobs reported cp-one 2>&1)"
reported_twice="$("$CP" jobs list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["reported_at"])')"
if [[ "$reported_once" == "$reported_twice" ]]; then
  ok "reported is idempotent (preserves first stamp)"
else
  fail "reported is idempotent (before=$reported_once after=$reported_twice)"
fi
if printf '%s\n' "$reported_again_out" | grep -F -q "reported_at=$reported_twice"; then
  ok "reported confirmation echoes existing stamp on re-run"
else
  fail "reported confirmation echoes existing stamp on re-run (stdout=$reported_again_out stamp=$reported_twice)"
fi
set_after_report="$("$CP" jobs list --json | python3 -c 'import json,sys; r=json.load(sys.stdin)[0]; print(r.get("reported_at",""))')"
"$CP" jobs set cp-one worker=crisp-oak >/dev/null
set_preserve_report="$("$CP" jobs list --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("reported_at",""))')"
if [[ -n "$set_after_report" && "$set_after_report" == "$set_preserve_report" ]]; then
  ok "set preserves reported_at"
else
  fail "set preserves reported_at (before=$set_after_report after=$set_preserve_report)"
fi
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
expect_exit 1 "reported rejects pr=" "$CP" jobs reported cp-keep pr=https://example.test/pull/1
expect_exit 1 "reported unknown id fails" "$CP" jobs reported cp-missing
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

# origin + empty reported_at round-trip through jobs reported (#85)
cat > "$CP_JOBS_FILE" <<EOF
#job	worker	worktree	branch	dispatched_at	reported_at	origin
cp-origin-report	old-worker	$WT	stamped-branch	2026-08-24T12:00:00Z		terminal
EOF
"$CP" jobs reported cp-origin-report >/dev/null
origin_report_row="$(awk -F'\t' '$1=="cp-origin-report"{print; exit}' "$CP_JOBS_FILE")"
if printf '%s\n' "$origin_report_row" | awk -F'\t' '
  $6 ~ /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/ && $7 == "terminal" {
    ok = 1
  }
  END { exit ok ? 0 : 1 }
'; then
  origin_nf="$(printf '%s\n' "$origin_report_row" | awk -F'\t' '{print NF; exit}')"
  if [[ "$origin_nf" == "7" ]]; then
    ok "reported preserves origin when reported_at was empty (NF==7, ISO \$6, \$7=origin)"
  else
    fail "reported preserves origin when reported_at was empty (want NF==7, got NF=$origin_nf row=$origin_report_row)"
  fi
else
  fail "reported preserves origin when reported_at was empty (row=$origin_report_row)"
fi

# confirmation must not go empty when later rows follow the target in jobs.tsv
"$CP" jobs add cp-before worker=before worktree="$TMP/wt" branch=feat/before >/dev/null
"$CP" jobs add cp-after worker=after worktree="$TMP/wt" branch=feat/after >/dev/null
before_out="$("$CP" jobs reported cp-before 2>&1)"
before_stamp="$("$CP" jobs list --json | python3 -c 'import json,sys; print(next(r["reported_at"] for r in json.load(sys.stdin) if r["job"]=="cp-before"))')"
if printf '%s\n' "$before_out" | grep -F -q "reported_at=$before_stamp"; then
  ok "reported confirmation echoes stamp when target is not the last row"
else
  fail "reported confirmation when not last row (stdout=$before_out stamp=$before_stamp)"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
