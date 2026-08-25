#!/usr/bin/env bash
# Unit tests for bin/cp status (single-shot read-only fleet snapshot; not a
# live dispatch E2E). Sources are stubbed: MUXA_WHO_CMD, MUXA_BROKER_CMD,
# BR_LIST_CMD, CP_JOBS_FILE. Fixtures live under $TMP (heredocs) plus one
# tracked golden file, test/fixtures/status/table.golden, for the human
# table. Branch-fallback and untracked join cases need a real git worktree
# (join step 3 runs `git -C cwd symbolic-ref --short HEAD`), so this suite
# builds a bare origin + clone + two linked worktrees, same pattern as
# test/occupancy.sh / test/teardown.sh. Run from the command-post repo:
# test/status.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$ROOT/bin/cp"
GOLDEN="$ROOT/test/fixtures/status/table.golden"
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-status.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
mkdir -p "$CP_HOME"

# --- git fixtures for the branch-fallback and untracked join cases -------
git init -q "$TMP/clone"
git -C "$TMP/clone" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
git -C "$TMP/clone" worktree add -q -b command-post-tst1 "$TMP/wt-branch-join" >/dev/null
git -C "$TMP/clone" worktree add -q -b scratch "$TMP/wt-scratch" >/dev/null
WT_BRANCH_JOIN="$(cd "$TMP/wt-branch-join" && pwd -P)"
WT_SCRATCH="$(cd "$TMP/wt-scratch" && pwd -P)"

# Plain (non-git) cwds for joins that never reach git (worker-name /
# worktree-column matches resolve before branch fallback is tried).
mkdir -p "$TMP/wt-worker" "$TMP/wt-worker2" "$TMP/wt-worktree-only" \
  "$TMP/wt-ghost" "$TMP/wt-closing" "$TMP/wt-orphan"

# --- fixtures --------------------------------------------------------------
cat > "$TMP/who.json" <<EOF
[
  {"name":"lucid-hawk","id":"a1","parent":null,"kind":"claude","state":"busy","pane":"%100","session":null,"cwd":"$TMP/home"},
  {"name":"rustic-otter","id":"a2","parent":"lucid-hawk","kind":"claude","state":"busy","pane":"%101","session":null,"cwd":"$TMP/wt-worker"},
  {"name":"vivid-river","id":"a3","parent":"lucid-hawk","kind":"claude","state":"idle","pane":"%102","session":null,"cwd":"$TMP/wt-worker2"},
  {"name":"quiet-fox","id":"a4","parent":"lucid-hawk","kind":"cursor","state":"busy","pane":"%103","session":null,"cwd":"$TMP/wt-worktree-only"},
  {"name":"branch-join-worker","id":"a5","parent":"lucid-hawk","kind":"cursor","state":"idle","pane":"%104","session":null,"cwd":"$WT_BRANCH_JOIN"},
  {"name":"lonely-wolf","id":"a6","parent":"lucid-hawk","kind":"claude","state":"busy","pane":"%105","session":null,"cwd":"$WT_SCRATCH"},
  {"name":"gone-ghost","id":"a7","parent":"lucid-hawk","kind":"claude","state":"ghost","pane":"%106","session":null,"cwd":"$TMP/wt-ghost"},
  {"name":"closing-crane","id":"a8","parent":"lucid-hawk","kind":"claude","state":"busy","pane":"%107","session":null,"cwd":"$TMP/wt-closing"}
]
EOF

cat > "$TMP/broker.json" <<'EOF'
{"ok":true,"pid":123,"queued":2,"done":5,"failed":0,"socket":"/tmp/fake.sock","drawing":["%101","%999"]}
EOF

cat > "$TMP/br-list.json" <<'EOF'
[
  {"id":"job-a","title":"Add widget","status":"open","priority":2,"issue_type":"task","updated_at":"2026-08-24T16:00:00Z","labels":["project:demo","delivery:pr","kind:ship"]},
  {"id":"job-b","title":"Fix widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T15:00:00Z","labels":["project:demo","delivery:pr","kind:ship"]},
  {"id":"job-c","title":"Worktree-joined widget","status":"open","priority":2,"issue_type":"task","updated_at":"2026-08-24T14:00:00Z","labels":["project:demo","delivery:local","kind:ship"]},
  {"id":"command-post-tst1","title":"Branch-joined widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T13:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-ghost","title":"Ghost-owning widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T12:00:00Z","labels":["project:demo"]},
  {"id":"job-orphan","title":"Orphaned widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T11:00:00Z","labels":["project:demo","kind:research"]}
]
EOF

cat > "$TMP/br-list-closed.json" <<'EOF'
[
  {"id":"job-closed","title":"Shipped widget","status":"closed","priority":2,"issue_type":"task","updated_at":"2026-08-24T10:00:00Z","labels":["project:demo","delivery:pr"]}
]
EOF

cat > "$TMP/jobs.tsv" <<EOF
#job	worker	worktree	branch
job-a	rustic-otter	$TMP/wt-worker	job-a
job-b	vivid-river	$TMP/wt-worker2	job-b
job-c	some-other-alias	$TMP/wt-worktree-only	job-c
job-ghost	gone-ghost	$TMP/wt-ghost	job-ghost
job-closed	closing-crane	$TMP/wt-closing	job-closed
job-orphan	vanished-worker	$TMP/wt-orphan	job-orphan
EOF
mkdir -p "$(dirname "$CP_JOBS_FILE")"
cp "$TMP/jobs.tsv" "$CP_JOBS_FILE"

cat > "$TMP/br-list-stub.sh" <<EOF
#!/bin/sh
set -eu
case "\$*" in
  *"-s closed"*) cat "$TMP/br-list-closed.json" ;;
  *) cat "$TMP/br-list.json" ;;
esac
EOF
chmod +x "$TMP/br-list-stub.sh"

export MUXA_WHO_CMD="cat $TMP/who.json"
export MUXA_BROKER_CMD="cat $TMP/broker.json"
export BR_LIST_CMD="$TMP/br-list-stub.sh"
export CP_STATUS_NOW="2026-08-24T16:10:00Z"

run_status() {
  "$CP" status --json
}

OUT="$(run_status)"

assert_py() {
  local label="$1" script="$2"
  if printf '%s' "$OUT" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}

# --- schema ------------------------------------------------------------
assert_py "schema: top-level keys" '
import json, sys
d = json.load(sys.stdin)
assert d["v"] == 1
assert d["generated_at"] == "2026-08-24T16:10:00Z"
assert isinstance(d["broker"], dict)
assert isinstance(d["nodes"], list)
assert isinstance(d["edges"], list)
'

assert_py "schema: every edge endpoint exists in nodes" '
import json, sys
d = json.load(sys.stdin)
ids = {n["id"] for n in d["nodes"]}
for e in d["edges"]:
    assert e["from"] in ids, e
    assert e["to"] in ids, e
'

assert_py "schema: glyph is a pure function of phase" '
import json, sys
d = json.load(sys.stdin)
seen = {}
for n in d["nodes"]:
    p, g = n["phase"], n["glyph"]
    if p in seen:
        assert seen[p] == g, (p, seen[p], g)
    else:
        seen[p] = g
'

# --- join matrix ---------------------------------------------------------
assert_py "join: worker-name match (rustic-otter)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "rustic-otter")
assert n["joined_via"] == "jobs.worker", n
assert n["br_id"] == "job-a", n
assert n["title"] == "Add widget", n
assert n["time_source"] == "br_updated_at", n
assert n["timestamp"] == "2026-08-24T16:00:00Z", n
'

assert_py "join: worktree fallback (quiet-fox, worker column mismatches pane name)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "quiet-fox")
assert n["joined_via"] == "jobs.worktree", n
assert n["br_id"] == "job-c", n
'

assert_py "join: branch fallback (real worktree, HEAD == br id)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "branch-join-worker")
assert n["joined_via"] == "branch", n
assert n["br_id"] == "command-post-tst1", n
'

assert_py "join: untracked pane (real worktree, non-br-id branch)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "lonely-wolf")
assert n["joined_via"] is None, n
assert n["br_id"] is None, n
assert n["title"] is None, n
assert n["phase"] == "untracked", n
assert n["glyph"] == "dash", n
'

assert_py "join: orphaned br in_progress issue with no live pane, enriched from jobs.tsv" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["br_id"] == "job-orphan")
assert n["id"] == "vanished-worker", n
assert n["pane"] is None, n
assert n["pane_state"] == "gone", n
assert n["phase"] == "orphaned", n
assert n["glyph"] == "warn", n
assert n["cwd"] == "'"$TMP"'/wt-orphan", n
assert n["kind"] == "research", n
'

assert_py "join: orphaned node gets an inferred edge from the root" '
import json, sys
d = json.load(sys.stdin)
assert {"from": "lucid-hawk", "to": "vanished-worker", "source": "inferred"} in d["edges"]
'

# --- full phase matrix (gap 1) -------------------------------------------
assert_py "phase: orchestrator busy, no br join -> working (not untracked)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "lucid-hawk")
assert n["role"] == "orchestrator", n
assert n["br_status"] is None, n
assert n["phase"] == "working", n
assert n["glyph"] == "dot", n
'

assert_py "phase: busy + br open -> working (the gap-1 undefined cell)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "rustic-otter")
assert n["br_status"] == "open", n
assert n["phase"] == "working", n
'

assert_py "phase: idle + br in_progress -> waiting" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "vivid-river")
assert n["phase"] == "waiting", n
assert n["glyph"] == "hollow", n
'

assert_py "phase: idle + br in_progress via branch join -> waiting" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "branch-join-worker")
assert n["phase"] == "waiting", n
'

assert_py "phase: ghost pane overrides an in_progress join -> ghost" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "gone-ghost")
assert n["br_status"] == "in_progress", n
assert n["phase"] == "ghost", n
assert n["glyph"] == "warn", n
'

assert_py "phase: live pane + closed br issue -> done (pre-teardown)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "closing-crane")
assert n["br_id"] == "job-closed", n
assert n["br_status"] == "closed", n
assert n["phase"] == "done", n
assert n["glyph"] == "check", n
'

assert_py "phase: gone + in_progress (no jobs row) -> orphaned" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["br_id"] == "job-orphan")
assert n["phase"] == "orphaned", n
'

# --- broker --------------------------------------------------------------
assert_py "broker: happy path resolves drawing pane ids to aliases, passes through unresolved ids" '
import json, sys
d = json.load(sys.stdin)
b = d["broker"]
assert b["ok"] is True, b
assert b["pid"] == 123, b
assert b["queued"] == 2, b
assert "rustic-otter" in b["drawing"], b
assert "%999" in b["drawing"], b
'

assert_py "broker: per-node drawing flag matches broker.drawing pane ids" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "rustic-otter")
assert n["drawing"] is True, n
n2 = next(x for x in d["nodes"] if x["id"] == "vivid-river")
assert n2["drawing"] is False, n2
'

# --- BR_LIST_CMD single-shim dispatch (gap 2) ----------------------------
expect_rc_msg 0 '"br_id": "job-a"' "BR_LIST_CMD serves the broad open/in_progress list" \
  "$CP" status --json

# --- purity: read-only, no mutation -------------------------------------
BEFORE_JOBS="$(cat "$CP_JOBS_FILE")"
run_status >/dev/null
AFTER_JOBS="$(cat "$CP_JOBS_FILE")"
if [[ "$BEFORE_JOBS" == "$AFTER_JOBS" ]]; then
  ok "status does not mutate state/jobs.tsv"
else
  fail "status does not mutate state/jobs.tsv"
fi

# --- broker degraded -------------------------------------------------------
export MUXA_BROKER_CMD=false
DEGRADED="$(run_status)"
unset MUXA_BROKER_CMD
export MUXA_BROKER_CMD="cat $TMP/broker.json"
assert_degraded() {
  local label="$1" script="$2"
  if printf '%s' "$DEGRADED" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}
assert_degraded "broker degraded: ok is false" '
import json, sys
d = json.load(sys.stdin)
assert d["broker"] == {"ok": False}, d["broker"]
'
assert_degraded "broker degraded: nodes are still emitted" '
import json, sys
d = json.load(sys.stdin)
assert len(d["nodes"]) > 0
'

# --- empty fleet ----------------------------------------------------------
EMPTY_TMP="$TMP/empty"
mkdir -p "$EMPTY_TMP"
printf '[]\n' > "$EMPTY_TMP/who.json"
printf '[]\n' > "$EMPTY_TMP/br-list.json"
printf '#job\tworker\tworktree\tbranch\n' > "$EMPTY_TMP/jobs.tsv"
cat > "$EMPTY_TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$EMPTY_TMP/br-list.json"
EOF
chmod +x "$EMPTY_TMP/br-list-stub.sh"
if (
  export CP_JOBS_FILE="$EMPTY_TMP/jobs.tsv"
  export MUXA_WHO_CMD="cat $EMPTY_TMP/who.json"
  export MUXA_BROKER_CMD="cat $TMP/broker.json"
  export BR_LIST_CMD="$EMPTY_TMP/br-list-stub.sh"
  EMPTY_OUT="$("$CP" status --json)"
  printf '%s' "$EMPTY_OUT" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["nodes"] == [], d["nodes"]
assert d["edges"] == [], d["edges"]
'
); then
  ok "empty fleet: nodes and edges are both []"
else
  fail "empty fleet: nodes and edges are both []"
fi

# --- human table (golden) --------------------------------------------------
TABLE_TMP="$TMP/table"
mkdir -p "$TABLE_TMP"
cat > "$TABLE_TMP/who.json" <<EOF
[
  {"name":"lucid-hawk","id":"a1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/home/demo"},
  {"name":"rustic-otter","id":"a2","parent":"lucid-hawk","kind":"claude","state":"busy","pane":"%2","session":null,"cwd":"/wt/demo"}
]
EOF
cat > "$TABLE_TMP/broker.json" <<'EOF'
{"ok":true,"pid":123,"queued":2,"done":5,"failed":0,"socket":"/tmp/fake.sock","drawing":["%2","%999"]}
EOF
cat > "$TABLE_TMP/br-list.json" <<'EOF'
[
  {"id":"job-a","title":"Add widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T16:00:00Z","labels":["project:demo","delivery:pr","kind:ship"]}
]
EOF
cat > "$TABLE_TMP/jobs.tsv" <<EOF
#job	worker	worktree	branch
job-a	rustic-otter	/wt/demo	job-a
EOF
cat > "$TABLE_TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$TABLE_TMP/br-list.json"
EOF
chmod +x "$TABLE_TMP/br-list-stub.sh"
TABLE_OUT="$(
  CP_JOBS_FILE="$TABLE_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $TABLE_TMP/who.json" \
  MUXA_BROKER_CMD="cat $TABLE_TMP/broker.json" \
  BR_LIST_CMD="$TABLE_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status
)"
if [[ -f "$GOLDEN" ]]; then
  if diff -u "$GOLDEN" <(printf '%s\n' "$TABLE_OUT") >/tmp/status-table.diff 2>&1; then
    ok "human table matches golden fixture"
  else
    fail "human table matches golden fixture ($(cat /tmp/status-table.diff))"
  fi
else
  fail "human table golden fixture missing: $GOLDEN"
fi

# --- quiet fleet: broker counters default to 0, not None -------------------
QUIET_TMP="$TMP/quiet"
mkdir -p "$QUIET_TMP"
cat > "$QUIET_TMP/who.json" <<'EOF'
[{"name":"solo-root","id":"a1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/home/demo"}]
EOF
cat > "$QUIET_TMP/broker.json" <<'EOF'
{"ok":true,"pid":1,"socket":"/tmp/fake.sock","drawing":[]}
EOF
printf '[]\n' > "$QUIET_TMP/br-list.json"
printf '#job\tworker\tworktree\tbranch\n' > "$QUIET_TMP/jobs.tsv"
cat > "$QUIET_TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$QUIET_TMP/br-list.json"
EOF
chmod +x "$QUIET_TMP/br-list-stub.sh"

QUIET_JSON="$(
  CP_JOBS_FILE="$QUIET_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $QUIET_TMP/who.json" \
  MUXA_BROKER_CMD="cat $QUIET_TMP/broker.json" \
  BR_LIST_CMD="$QUIET_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status --json
)"
if printf '%s' "$QUIET_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
b = d["broker"]
assert b["ok"] is True
assert b["queued"] == 0, b["queued"]
assert b["done"] == 0, b["done"]
assert b["failed"] == 0, b["failed"]
'; then
  ok "quiet fleet JSON: missing broker counters default to 0"
else
  fail "quiet fleet JSON: missing broker counters default to 0"
fi

QUIET_TABLE="$(
  CP_JOBS_FILE="$QUIET_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $QUIET_TMP/who.json" \
  MUXA_BROKER_CMD="cat $QUIET_TMP/broker.json" \
  BR_LIST_CMD="$QUIET_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status
)"
if printf '%s\n' "$QUIET_TABLE" | grep -F -q 'BROKER ok queued=0 done=0 failed=0'; then
  ok "quiet fleet human table: queued=0 not None"
else
  fail "quiet fleet human table: queued=0 not None (out: $QUIET_TABLE)"
fi

# --- HTML snapshot -------------------------------------------------------
printf '%s' "$OUT" > "$TMP/expected-status.json"
export STATUS_EXPECTED_JSON="$TMP/expected-status.json"
HTML_OUT="$(
  CP_JOBS_FILE="$CP_JOBS_FILE" \
  MUXA_WHO_CMD="$MUXA_WHO_CMD" \
  MUXA_BROKER_CMD="$MUXA_BROKER_CMD" \
  BR_LIST_CMD="$BR_LIST_CMD" \
  CP_STATUS_NOW="$CP_STATUS_NOW" \
  "$CP" status --html
)"

assert_html() {
  local label="$1" script="$2"
  if printf '%s' "$HTML_OUT" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}

assert_html "html: single self-contained document" '
import sys
doc = sys.stdin.read()
assert doc.startswith("<!DOCTYPE html>"), doc[:80]
assert doc.strip().endswith("</html>"), doc[-80:]
assert doc.count("<html") == 1
'

assert_html "html: embeds JSON payload verbatim" '
import json, re, sys
doc = sys.stdin.read()
m = re.search(r"<script type=\"application/json\" id=\"fleet-data\">(.*?)</script>", doc, re.S)
assert m, "missing fleet-data script"
embedded = m.group(1)
payload = json.loads(embedded)
assert payload["v"] == 1
assert payload["generated_at"] == "2026-08-24T16:10:00Z"
assert len(payload["nodes"]) > 0
'

assert_html "html: no external URL references" '
import re, sys
doc = sys.stdin.read()
assert not re.search(r"https?://", doc), "http(s) URL found"
assert not re.search(r"@import", doc), "@import found"
assert not re.search(r"<link[^>]+href=", doc), "external link tag found"
assert not re.search(r"<script[^>]+src=", doc), "external script tag found"
'

assert_html "html: payload matches --json for same fleet" '
import json, os, re, sys
doc = sys.stdin.read()
m = re.search(r"<script type=\"application/json\" id=\"fleet-data\">(.*?)</script>", doc, re.S)
embedded = json.loads(m.group(1))
expected = json.load(open(os.environ["STATUS_EXPECTED_JSON"]))
assert embedded == expected
'

QUIET_HTML="$(
  CP_JOBS_FILE="$QUIET_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $QUIET_TMP/who.json" \
  MUXA_BROKER_CMD="cat $QUIET_TMP/broker.json" \
  BR_LIST_CMD="$QUIET_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status --html
)"
if printf '%s' "$QUIET_HTML" | python3 -c '
import json, re, sys
doc = sys.stdin.read()
m = re.search(r"<script type=\"application/json\" id=\"fleet-data\">(.*?)</script>", doc, re.S)
assert m
payload = json.loads(m.group(1))
assert payload["broker"]["queued"] == 0
'; then
  ok "quiet fleet html: embedded payload has queued=0"
else
  fail "quiet fleet html: embedded payload has queued=0"
fi

# --- dispatched_at vs legacy br.updated_at proxy -------------------------
TIME_TMP="$TMP/time-source"
mkdir -p "$TIME_TMP"
cat > "$TIME_TMP/who.json" <<EOF
[
  {"name":"root-pane","id":"r1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"$TMP/home"},
  {"name":"stamped-worker","id":"w1","parent":"root-pane","kind":"cursor","state":"busy","pane":"%2","session":null,"cwd":"$TMP/wt-stamped"},
  {"name":"legacy-worker","id":"w2","parent":"root-pane","kind":"cursor","state":"busy","pane":"%3","session":null,"cwd":"$TMP/wt-legacy"}
]
EOF
mkdir -p "$TIME_TMP/wt-stamped" "$TIME_TMP/wt-legacy"
cat > "$TIME_TMP/broker.json" <<'EOF'
{"ok":true,"pid":1,"queued":0,"done":0,"failed":0,"socket":"/tmp/fake.sock","drawing":[]}
EOF
cat > "$TIME_TMP/br-list.json" <<'EOF'
[
  {"id":"job-stamped","title":"Stamped job","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-legacy","title":"Legacy job","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]}
]
EOF
cat > "$TIME_TMP/jobs.tsv" <<EOF
#job	worker	worktree	branch
job-stamped	stamped-worker	$TMP/wt-stamped	job-stamped	2026-08-24T16:08:00Z
job-legacy	legacy-worker	$TMP/wt-legacy	job-legacy
EOF
cat > "$TIME_TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$TIME_TMP/br-list.json"
EOF
chmod +x "$TIME_TMP/br-list-stub.sh"

TIME_JSON="$(
  CP_JOBS_FILE="$TIME_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $TIME_TMP/who.json" \
  MUXA_BROKER_CMD="cat $TIME_TMP/broker.json" \
  BR_LIST_CMD="$TIME_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status --json
)"

assert_time() {
  local label="$1" script="$2"
  if printf '%s' "$TIME_JSON" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}

assert_time "time_source: stamped row uses dispatched_at (2m age)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "stamped-worker")
assert n["time_source"] == "dispatched_at", n
assert n["timestamp"] == "2026-08-24T16:08:00Z", n
'

assert_time "time_source: legacy 4-column row keeps br_updated_at proxy (4d age)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "legacy-worker")
assert n["time_source"] == "br_updated_at", n
assert n["timestamp"] == "2026-08-20T08:00:00Z", n
'

TIME_HTML="$(
  CP_JOBS_FILE="$TIME_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $TIME_TMP/who.json" \
  MUXA_BROKER_CMD="cat $TIME_TMP/broker.json" \
  BR_LIST_CMD="$TIME_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  "$CP" status --html
)"
if printf '%s' "$TIME_HTML" | python3 -c '
import json, re, sys
doc = sys.stdin.read()
assert "dispatched_at" in doc
assert "br_updated_at" in doc
m = re.search(r"<script type=\"application/json\" id=\"fleet-data\">(.*?)</script>", doc, re.S)
payload = json.loads(m.group(1))
by_id = {n["id"]: n for n in payload["nodes"]}
assert by_id["stamped-worker"]["time_source"] == "dispatched_at"
assert by_id["legacy-worker"]["time_source"] == "br_updated_at"
assert "TIME_SOURCE_LABEL" in doc
assert "dispatched_at:" in doc
assert "br_updated_at:" in doc
'; then
  ok "html: mixed fleet shows both time_source markers"
else
  fail "html: mixed fleet shows both time_source markers"
fi

# --- stalled / held detection ---------------------------------------------
STALL_TMP="$TMP/stall"
mkdir -p "$STALL_TMP/wt-stalled" "$STALL_TMP/wt-fresh" "$STALL_TMP/wt-legacy" "$STALL_TMP/wt-recent" "$STALL_TMP/wt-held"
cat > "$STALL_TMP/who.json" <<EOF
[
  {"name":"root-pane","id":"r1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"$TMP/home"},
  {"name":"stalled-worker","id":"w1","parent":"root-pane","kind":"cursor","state":"idle","pane":"%2","session":null,"cwd":"$STALL_TMP/wt-stalled"},
  {"name":"fresh-worker","id":"w2","parent":"root-pane","kind":"cursor","state":"idle","pane":"%3","session":null,"cwd":"$STALL_TMP/wt-fresh"},
  {"name":"legacy-worker","id":"w3","parent":"root-pane","kind":"cursor","state":"idle","pane":"%4","session":null,"cwd":"$STALL_TMP/wt-legacy"},
  {"name":"recent-worker","id":"w4","parent":"root-pane","kind":"cursor","state":"idle","pane":"%5","session":null,"cwd":"$STALL_TMP/wt-recent"},
  {"name":"held-worker","id":"w5","parent":"root-pane","kind":"cursor","state":"idle","pane":"%6","session":null,"cwd":"$STALL_TMP/wt-held"}
]
EOF
cat > "$STALL_TMP/broker.json" <<'EOF'
{"ok":true,"pid":1,"queued":0,"done":0,"failed":0,"socket":"/tmp/fake.sock","drawing":[]}
EOF
cat > "$STALL_TMP/br-list.json" <<'EOF'
[
  {"id":"job-stalled","title":"Stalled job","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-fresh","title":"Fresh idle job","status":"open","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-legacy","title":"Legacy idle job","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-recent","title":"Recent idle job","status":"open","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-held","title":"Held after report","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-20T08:00:00Z","labels":["project:demo","delivery:pr"]}
]
EOF
cat > "$STALL_TMP/jobs.tsv" <<EOF
#job	worker	worktree	branch
job-stalled	stalled-worker	$STALL_TMP/wt-stalled	job-stalled	2026-08-24T15:50:00Z
job-fresh	fresh-worker	$STALL_TMP/wt-fresh	job-fresh	2026-08-24T16:05:00Z
job-legacy	legacy-worker	$STALL_TMP/wt-legacy	job-legacy
job-recent	recent-worker	$STALL_TMP/wt-recent	job-recent	2026-08-24T16:09:00Z
job-held	held-worker	$STALL_TMP/wt-held	job-held	2026-08-24T15:50:00Z	2026-08-24T16:00:00Z
EOF
cat > "$STALL_TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$STALL_TMP/br-list.json"
EOF
chmod +x "$STALL_TMP/br-list-stub.sh"

STALL_JSON="$(
  CP_JOBS_FILE="$STALL_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $STALL_TMP/who.json" \
  MUXA_BROKER_CMD="cat $STALL_TMP/broker.json" \
  BR_LIST_CMD="$STALL_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  CP_STATUS_STALL_SEC=600 \
  "$CP" status --json
)"

assert_stall() {
  local label="$1" script="$2"
  if printf '%s' "$STALL_JSON" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}

assert_stall "stalled: idle + open br + dispatched_at older than threshold -> stalled" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "stalled-worker")
assert n["phase"] == "stalled", n
assert n["glyph"] == "cross", n
assert n["time_source"] == "dispatched_at", n
'

assert_stall "held: idle + open br + reported_at -> held (not stalled)" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "held-worker")
assert n["phase"] == "held", n
assert n["glyph"] == "ring", n
assert n["time_source"] == "dispatched_at", n
'

assert_stall "held: old dispatched_at with reported_at never stalls" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "held-worker")
assert n["phase"] != "stalled", n
'

assert_stall "stalled: fresh idle row within threshold stays waiting" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "fresh-worker")
assert n["phase"] == "waiting", n
assert n["glyph"] == "hollow", n
'

assert_stall "stalled: legacy row without dispatched_at stays waiting" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "legacy-worker")
assert n["phase"] == "waiting", n
assert n["time_source"] == "br_updated_at", n
'

assert_stall "stalled: idle but recently dispatched stays waiting" '
import json, sys
d = json.load(sys.stdin)
n = next(x for x in d["nodes"] if x["id"] == "recent-worker")
assert n["phase"] == "waiting", n
assert n["time_source"] == "dispatched_at", n
'

STALL_TABLE="$(
  CP_JOBS_FILE="$STALL_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $STALL_TMP/who.json" \
  MUXA_BROKER_CMD="cat $STALL_TMP/broker.json" \
  BR_LIST_CMD="$STALL_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  CP_STATUS_STALL_SEC=600 \
  "$CP" status
)"
if printf '%s\n' "$STALL_TABLE" | python3 -c '
import sys
lines = {l.split()[0]: l for l in sys.stdin.read().splitlines() if l and not l.startswith("ALIAS") and not l.startswith("BROKER")}
assert lines["stalled-worker"].split()[2] == "stalled", lines["stalled-worker"]
assert lines["held-worker"].split()[2] == "held", lines["held-worker"]
'; then
  ok "stalled/held: human table shows distinct phases"
else
  fail "stalled/held: human table shows distinct phases (out: $STALL_TABLE)"
fi

STALL_HTML="$(
  CP_JOBS_FILE="$STALL_TMP/jobs.tsv" \
  MUXA_WHO_CMD="cat $STALL_TMP/who.json" \
  MUXA_BROKER_CMD="cat $STALL_TMP/broker.json" \
  BR_LIST_CMD="$STALL_TMP/br-list-stub.sh" \
  CP_STATUS_NOW="2026-08-24T16:10:00Z" \
  CP_STATUS_STALL_SEC=600 \
  "$CP" status --html
)"
if printf '%s' "$STALL_HTML" | python3 -c '
import json, re, sys
doc = sys.stdin.read()
assert "phase-stalled" in doc
assert "phase-held" in doc
m = re.search(r"<script type=\"application/json\" id=\"fleet-data\">(.*?)</script>", doc, re.S)
payload = json.loads(m.group(1))
stalled = next(x for x in payload["nodes"] if x["id"] == "stalled-worker")
held = next(x for x in payload["nodes"] if x["id"] == "held-worker")
assert stalled["phase"] == "stalled"
assert stalled["glyph"] == "cross"
assert held["phase"] == "held"
assert held["glyph"] == "ring"
'; then
  ok "stalled/held: html rendering includes both phases and glyphs"
else
  fail "stalled/held: html rendering includes both phases and glyphs"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
