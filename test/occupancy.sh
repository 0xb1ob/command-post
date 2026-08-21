#!/usr/bin/env bash
# Unit tests for bin/cp check occupancy via muxa who --json (stubbed; not a
# live dispatch E2E). Occupancy is the JSON roster shape, never the human
# table, and never who --json's exit status (pre-#49 printed the table with
# exit 0). Run from the command-post repo: test/occupancy.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-occ.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
CLONE="$CP_HOME/projects/demo"
mkdir -p "$CLONE"
git -C "$CLONE" init -q -b main
git -C "$CLONE" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
git -C "$CLONE" worktree add -q "$TMP/wt" >/dev/null
WT="$(cd "$TMP/wt" && pwd -P)"

who_fixture() {
  cat > "$TMP/who.json"
}

set_who() {
  who_fixture
  MUXA_WHO_CMD="cat $TMP/who.json"
  export MUXA_WHO_CMD
}

# empty roster → occupancy clear
set_who <<'EOF'
[]
EOF
expect_rc_msg 0 "clear: no other live registered worker" "empty who --json is clear" \
  "$CP" check --project demo "$WT"

# live occupant → promote-not-spawn; remedy names muxa send X
set_who <<EOF
[{"name":"swift-oak","id":"abc","parent":null,"kind":"cursor","state":"idle","pane":"%1","session":null,"cwd":"$WT","status":"live"}]
EOF
expect_rc_msg 1 "promote-not-spawn: live worker swift-oak occupies" "live occupant is promote-not-spawn" \
  "$CP" check --project demo "$WT"
expect_rc_msg 1 "muxa send swift-oak" "promote remedy names muxa send X" \
  "$CP" check --project demo "$WT"
expect_rc_msg 1 "do not muxa dispatch" "live occupant forbids a second dispatch" \
  "$CP" check --project demo "$WT"

# ghost occupant
set_who <<EOF
[{"name":"gone-fox","id":"def","parent":"crisp-oak","kind":"cursor","state":"idle","pane":"%2","session":null,"cwd":"$WT","status":"ghost"}]
EOF
expect_rc_msg 1 "ghost worker gone-fox" "ghost occupant is occupied-cwd" \
  "$CP" check --project demo "$WT"
expect_rc_msg 1 "muxa kill NAME|ID" "ghost remedy is muxa kill NAME|ID" \
  "$CP" check --project demo "$WT"
expect_rc_msg 1 "restart the CLI in that pane" "ghost remedy offers restarting the CLI" \
  "$CP" check --project demo "$WT"

# skip self
export MUXA_WHOAMI=swift-oak
set_who <<EOF
[{"name":"swift-oak","id":"abc","parent":null,"kind":"cursor","state":"busy","pane":"%1","session":null,"cwd":"$WT","status":"live"}]
EOF
expect_rc_msg 0 "clear: no other live registered worker" "self on the worktree is not a collision" \
  "$CP" check --project demo "$WT"
unset MUXA_WHOAMI

# other cwd does not collide
set_who <<EOF
[{"name":"other-owl","id":"xyz","parent":null,"kind":"claude","state":"idle","pane":"%3","session":null,"cwd":"/tmp/elsewhere","status":"live"}]
EOF
expect_rc_msg 0 "clear: no other live registered worker" "live worker on another cwd is clear" \
  "$CP" check --project demo "$WT"

# human table with exit 0 is not occupancy-clear (pre-#49 who --json)
set_who <<'EOF'
NAME             ID     STATUS   CWD
swift-oak        abc    live     /tmp/wt
EOF
expect_rc_msg 2 "not JSON" "human who table with exit 0 is rejected (shape, not status)" \
  "$CP" check --project demo "$WT"

# object instead of array
set_who <<'EOF'
{"name":"swift-oak","status":"live","cwd":"/tmp"}
EOF
expect_rc_msg 2 "expected an array" "who --json object (not array) is rejected" \
  "$CP" check --project demo "$WT"

# array of non-objects
set_who <<'EOF'
["swift-oak", "live"]
EOF
expect_rc_msg 2 "expected objects" "who --json array of non-objects is rejected" \
  "$CP" check --project demo "$WT"

# occupancy keys name/status/cwd; extra fields are ignored (JSON shape, not table)
set_who <<EOF
[{"name":"lean-jay","status":"live","cwd":"$WT","extra":true}]
EOF
expect_rc_msg 1 "promote-not-spawn: live worker lean-jay occupies" "minimal JSON shape is enough to occupy" \
  "$CP" check --project demo "$WT"

# stub that exits 0 after printing the human table (explicit status-vs-shape)
cat > "$TMP/who-table.sh" <<'EOF'
#!/bin/sh
printf '%s\n' 'NAME  ID  STATUS  CWD' 'swift-oak  abc  live  /tmp/wt'
exit 0
EOF
chmod +x "$TMP/who-table.sh"
MUXA_WHO_CMD="$TMP/who-table.sh"
export MUXA_WHO_CMD
expect_rc_msg 2 "not JSON" "who stub exit 0 + human table still fail-closes on shape" \
  "$CP" check --project demo "$WT"

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
