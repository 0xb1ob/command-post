#!/usr/bin/env bash
# Unit tests for bin/cp status --serve (foreground localhost dashboard).
# Sources are stubbed like test/status.sh. Always kills the background server
# via trap; no GNU timeout required.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-status-serve.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
mkdir -p "$CP_HOME"

cat > "$TMP/who.json" <<'EOF'
[{"name":"solo-root","id":"a1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/home/demo"}]
EOF

cat > "$TMP/broker.json" <<'EOF'
{"ok":true,"pid":1,"queued":0,"done":0,"failed":0,"socket":"/tmp/fake.sock","drawing":[]}
EOF

cat > "$TMP/br-list.json" <<'EOF'
[{"id":"job-a","title":"Add widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T16:00:00Z","labels":["project:demo","delivery:pr"]}]
EOF

cat > "$TMP/jobs.tsv" <<'EOF'
#job	worker	worktree	branch
job-a	solo-root	/home/demo	job-a
EOF
mkdir -p "$(dirname "$CP_JOBS_FILE")"
cp "$TMP/jobs.tsv" "$CP_JOBS_FILE"

cat > "$TMP/br-list-stub.sh" <<EOF
#!/bin/sh
exec cat "$TMP/br-list.json"
EOF
chmod +x "$TMP/br-list-stub.sh"

export MUXA_WHO_CMD="cat $TMP/who.json"
export MUXA_BROKER_CMD="cat $TMP/broker.json"
export BR_LIST_CMD="$TMP/br-list-stub.sh"
export CP_STATUS_NOW="2026-08-24T16:10:00Z"

pick_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

wait_curl() {
  local url="$1" tries="${2:-50}"
  local i=0
  while [[ "$i" -lt "$tries" ]]; do
    if curl -sf "$url" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    sleep 0.1
  done
  return 1
}

start_server() {
  local port="$1"
  PORT="$port"
  URL_OUT="$TMP/url.out"
  SERVE_ERR="$TMP/serve.err"
  : >"$URL_OUT"
  : >"$SERVE_ERR"
  "$CP" status --serve --port "$port" >"$URL_OUT" 2>"$SERVE_ERR" &
  SERVE_PID=$!
  trap 'kill "$SERVE_PID" 2>/dev/null; wait "$SERVE_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
  local i=0
  while [[ "$i" -lt 50 ]]; do
    if [[ -s "$URL_OUT" ]]; then
      break
    fi
    if ! kill -0 "$SERVE_PID" 2>/dev/null; then
      fail "server exited before printing URL (stderr: $(cat "$SERVE_ERR"))"
      return 1
    fi
    i=$((i + 1))
    sleep 0.1
  done
  if [[ ! -s "$URL_OUT" ]]; then
    fail "server never printed URL"
    return 1
  fi
  if ! wait_curl "http://127.0.0.1:${port}/api/status"; then
    fail "server /api/status not reachable on port $port"
    return 1
  fi
  ok "server started on port $port"
}

PORT="$(pick_port)"
start_server "$PORT" || true

# --- stdout URL ------------------------------------------------------------
URL_LINE="$(head -n1 "$URL_OUT")"
if [[ "$URL_LINE" == "http://127.0.0.1:${PORT}/" ]]; then
  ok "stdout URL matches http://127.0.0.1:PORT/"
else
  fail "stdout URL matches http://127.0.0.1:PORT/ (got: $URL_LINE)"
fi

# --- flag exclusivity ------------------------------------------------------
expect_rc_msg 2 "mutually exclusive" "--serve --json is rejected" \
  env MUXA_WHO_CMD="$MUXA_WHO_CMD" MUXA_BROKER_CMD="$MUXA_BROKER_CMD" \
  BR_LIST_CMD="$BR_LIST_CMD" CP_JOBS_FILE="$CP_JOBS_FILE" CP_STATUS_NOW="$CP_STATUS_NOW" CP_HOME="$CP_HOME" \
  "$CP" status --serve --json

expect_rc_msg 2 "mutually exclusive" "--serve --html is rejected" \
  env MUXA_WHO_CMD="$MUXA_WHO_CMD" MUXA_BROKER_CMD="$MUXA_BROKER_CMD" \
  BR_LIST_CMD="$BR_LIST_CMD" CP_JOBS_FILE="$CP_JOBS_FILE" CP_STATUS_NOW="$CP_STATUS_NOW" CP_HOME="$CP_HOME" \
  "$CP" status --serve --html

JSON_DIRECT="$("$CP" status --json)"
if printf '%s' "$JSON_DIRECT" | python3 -c 'import json,sys; json.load(sys.stdin)'; then
  ok "bare status --json still dump-and-exit"
else
  fail "bare status --json still dump-and-exit"
fi

# --- parity: /api/status == status --json ----------------------------------
API_JSON="$(curl -sf "http://127.0.0.1:${PORT}/api/status")"
printf '%s' "$API_JSON" > "$TMP/api.json"
printf '%s' "$JSON_DIRECT" > "$TMP/direct.json"
if python3 -c '
import json
a = json.load(open("'"$TMP"'/api.json"))
b = json.load(open("'"$TMP"'/direct.json"))
assert a == b, (a, b)
'; then
  ok "GET /api/status JSON equals status --json"
else
  fail "GET /api/status JSON equals status --json"
fi

# --- HTML ------------------------------------------------------------------
HTML_PAGE="$(curl -sf "http://127.0.0.1:${PORT}/")"
assert_html() {
  local label="$1" script="$2"
  if printf '%s' "$HTML_PAGE" | python3 -c "$script"; then
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

assert_html "html: polls /api/status via fetch" '
import sys
doc = sys.stdin.read()
assert "fetch" in doc
assert "/api/status" in doc
'

assert_html "html: no external URL references" '
import re, sys
doc = sys.stdin.read()
assert not re.search(r"https?://", doc), "http(s) URL found"
assert not re.search(r"@import", doc), "@import found"
assert not re.search(r"<link[^>]+href=", doc), "external link tag found"
assert not re.search(r"<script[^>]+src=", doc), "external script tag found"
'

assert_html "html: error banner element present" '
import sys
doc = sys.stdin.read()
assert "error-banner" in doc
'

# --- liveness: fresh assemble per request ----------------------------------
BASE_JSON="$(curl -sf "http://127.0.0.1:${PORT}/api/status")"
cat > "$TMP/who.json" <<'EOF'
[{"name":"solo-root","id":"a1","parent":null,"kind":"claude","state":"idle","pane":"%1","session":null,"cwd":"/home/demo"},{"name":"extra-pane","id":"a2","parent":"solo-root","kind":"cursor","state":"busy","pane":"%2","session":null,"cwd":"/home/demo2"}]
EOF
LIVE_JSON="$(curl -sf "http://127.0.0.1:${PORT}/api/status")"
if [[ "$BASE_JSON" != "$LIVE_JSON" ]] && printf '%s' "$LIVE_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["nodes"]) == 2, d["nodes"]
'; then
  ok "mutated who.json reflected on next GET (no cache)"
else
  fail "mutated who.json reflected on next GET (no cache)"
fi
cat > "$TMP/who.json" <<'EOF'
[{"name":"solo-root","id":"a1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"/home/demo"}]
EOF

# --- purity ----------------------------------------------------------------
BEFORE_JOBS="$(cat "$CP_JOBS_FILE")"
for _ in 1 2 3; do
  curl -sf "http://127.0.0.1:${PORT}/api/status" >/dev/null
  curl -sf "http://127.0.0.1:${PORT}/" >/dev/null
done
AFTER_JOBS="$(cat "$CP_JOBS_FILE")"
if [[ "$BEFORE_JOBS" == "$AFTER_JOBS" ]]; then
  ok "serve does not mutate state/jobs.tsv"
else
  fail "serve does not mutate state/jobs.tsv"
fi

# --- bind conflict ---------------------------------------------------------
expect_rc_msg 2 "cannot bind" "second --serve on same port exits 2" \
  env MUXA_WHO_CMD="$MUXA_WHO_CMD" MUXA_BROKER_CMD="$MUXA_BROKER_CMD" \
  BR_LIST_CMD="$BR_LIST_CMD" CP_JOBS_FILE="$CP_JOBS_FILE" CP_STATUS_NOW="$CP_STATUS_NOW" CP_HOME="$CP_HOME" \
  "$CP" status --serve --port "$PORT"

# --- localhost listener ----------------------------------------------------
if python3 -c "import socket; s=socket.create_connection(('127.0.0.1', $PORT), 1); s.close()"; then
  ok "listener accepts 127.0.0.1:$PORT"
else
  fail "listener accepts 127.0.0.1:$PORT"
fi

# --- broker degrade --------------------------------------------------------
kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
trap 'rm -rf "$TMP"' EXIT

DEG_PORT="$(pick_port)"
export MUXA_BROKER_CMD=false
"$CP" status --serve --port "$DEG_PORT" >"$TMP/deg-url.out" 2>"$TMP/deg.err" &
DEG_PID=$!
trap 'kill "$DEG_PID" 2>/dev/null; wait "$DEG_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
wait_curl "http://127.0.0.1:${DEG_PORT}/api/status" || fail "degraded server unreachable"

DEG_JSON="$(curl -sf "http://127.0.0.1:${DEG_PORT}/api/status")"
if printf '%s' "$DEG_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["broker"] == {"ok": False}, d["broker"]
assert len(d["nodes"]) > 0
'; then
  ok "broker degrade: /api/status ok=false with nodes"
else
  fail "broker degrade: /api/status ok=false with nodes"
fi
unset MUXA_BROKER_CMD
export MUXA_BROKER_CMD="cat $TMP/broker.json"

kill "$DEG_PID" 2>/dev/null || true
wait "$DEG_PID" 2>/dev/null || true
trap 'rm -rf "$TMP"' EXIT

# --- python3 missing -------------------------------------------------------
NOPORT="$(pick_port)"
NOPATH_DIR="$TMP/nopython"
mkdir -p "$NOPATH_DIR"
# Minimal PATH: shell utilities without python3 (pyenv shims excluded).
SANPATH="/bin:/usr/bin:/sbin:/usr/sbin"
if PATH="$SANPATH" command -v python3 >/dev/null 2>&1; then
  ok "status --serve without python3 (skipped: python3 on minimal PATH)"
else
  rc=0
  out="$(PATH="$SANPATH" CP_HOME="$CP_HOME" "$CP" status --serve --port "$NOPORT" 2>&1)" || rc=$?
  if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -F -q 'python3 not on PATH (needed for status)'; then
    ok "status --serve without python3 (exit 2)"
  else
    fail "status --serve without python3 (want exit 2, got $rc; out: $out)"
  fi
fi

printf '\n%d test(s); %d failed\n' "$n" "$failed"
[[ "$failed" -eq 0 ]]
