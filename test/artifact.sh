#!/usr/bin/env bash
# Unit tests for bin/cp artifact (isolated temp br db; not HOME or this worktree).
# Run from the command-post repo: test/artifact.sh
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

if ! command -v br >/dev/null 2>&1; then
  printf 'br not on PATH (needed for artifact tests)\n' >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-artifact.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME" "$TMP/elsewhere"

# path does not need .beads; it is HOME-relative, not $PWD
report="$("$CP" artifact path t-one)"
want="$CP_HOME/state/artifacts/t-one/report.md"
if [[ "$report" == "$want" ]]; then
  ok "path prints HOME state/artifacts/<id>/report.md"
else
  fail "path prints HOME report (want $want, got $report)"
fi
if [[ -d "$CP_HOME/state/artifacts/t-one" ]]; then
  ok "path creates the artifacts directory"
else
  fail "path creates the artifacts directory"
fi

# cwd must not change where the path lands
got="$(
  # shellcheck disable=SC2164
  cd "$TMP/elsewhere"
  "$CP" artifact path t-cwd
)"
if [[ "$got" == "$CP_HOME/state/artifacts/t-cwd/report.md" ]]; then
  ok "path is resolved from HOME, not \$PWD"
else
  fail "path is resolved from HOME, not \$PWD (got $got)"
fi

# add/get fail closed with no .beads (and must not create one in CP_HOME or a worktree cwd)
expect_exit 1 "add fails when HOME has no .beads" "$CP" artifact add t-one "$TMP/elsewhere/x"
expect_exit 1 "get fails when HOME has no .beads" "$CP" artifact get t-one
# Do not assert on repo-root .beads — install.sh legitimately init's there; the hazard
# is cp/br auto-initing under CP_HOME or a leased worktree when none exists yet.
if [[ ! -e "$CP_HOME/.beads" && ! -e "$TMP/elsewhere/.beads" ]]; then
  ok "missing .beads does not auto-init a tracker"
else
  fail "missing .beads does not auto-init a tracker"
fi

# Isolated tracker under CP_HOME only (never repo HOME, never this worktree).
(
  cd "$CP_HOME"
  br init --prefix t >/dev/null
)
DB="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CP_HOME/.beads/beads.db")"
ID="$(br --db "$DB" create "artifact-test" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

# Special-character payload; unique token must never appear on add stdout.
printf 'hello `ticks` and "quotes" and $HOME and $(echo hi)\nline two\n' > "$TMP/src.md"
src_bytes="$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$TMP/src.md")"
add_out="$("$CP" artifact add "$ID" "$TMP/src.md")"
if printf '%s\n' "$add_out" | AID="$ID" ABYTES="$src_bytes" python3 -c 'import json,os,sys
d=json.load(sys.stdin)
assert d["br_id"]==os.environ["AID"]
assert d["bytes"]==int(os.environ["ABYTES"])
'; then
  ok "add prints {br_id, bytes} JSON"
else
  fail "add prints {br_id, bytes} JSON (got $add_out)"
fi
if printf '%s\n' "$add_out" | grep -F -q 'ticks'; then
  fail "add does not print the body"
else
  ok "add does not print the body"
fi
if [[ -f "$TMP/src.md" ]]; then
  ok "add leaves the source file in place"
else
  fail "add leaves the source file in place"
fi

"$CP" artifact get "$ID" > "$TMP/got1.md"
if cmp -s "$TMP/src.md" "$TMP/got1.md"; then
  ok "get returns the body with the marker stripped"
else
  fail "get returns the body with the marker stripped"
fi

# Newest artifact:v1 wins; ordinary comments are ignored.
printf 'revision-two payload\n' > "$TMP/src2.md"
"$CP" artifact add "$ID" "$TMP/src2.md" >/dev/null
br --db "$DB" comments add "$ID" "ordinary note, not an artifact" -q >/dev/null
"$CP" artifact get "$ID" > "$TMP/got2.md"
if cmp -s "$TMP/src2.md" "$TMP/got2.md"; then
  ok "get returns the newest artifact:v1 comment"
else
  fail "get returns the newest artifact:v1 comment"
fi

# No artifact on a fresh issue
ID2="$(br --db "$DB" create "no-artifact" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
rc=0
out="$("$CP" artifact get "$ID2" 2>/dev/null)" || rc=$?
if [[ "$rc" -eq 1 && -z "$out" ]]; then
  ok "get fails closed with empty stdout when no artifact comment exists"
else
  fail "get fails closed with empty stdout when no artifact comment exists (rc=$rc out=$(printf %q "$out"))"
fi

expect_exit 2 "artifact without subcommand is usage" "$CP" artifact
expect_exit 2 "unknown artifact subcommand is usage" "$CP" artifact frob
expect_exit 2 "add without file is usage" "$CP" artifact add "$ID"
expect_exit 1 "whitespace id refused" "$CP" artifact path "cp foo"
expect_exit 1 "add missing file fails" "$CP" artifact add "$ID" "$TMP/missing.md"

# Workers may write companion files beside the mirrored report path (see teardown guard).
companion_id="t-companion"
companion_report="$("$CP" artifact path "$companion_id")"
companion_dir="$(dirname "$companion_report")"
printf 'companion data\n' > "$companion_dir/summary.tsv"
if [[ -f "$companion_dir/summary.tsv" && -d "$companion_dir" ]]; then
  ok "companion files may live beside artifact report path"
else
  fail "companion files may live beside artifact report path"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
