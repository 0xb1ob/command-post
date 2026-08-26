#!/usr/bin/env bash
# Unit tests for bin/cp threads and bin/cp relay: the Slack steering plane's
# outbound half. No Slack app, no live credentials, no network to slack.com --
# CP_SLACK_API_BASE points chat.postMessage at a local python stub, so the post
# path is exercised for real while staying offline. Sources are stubbed the same
# way as test/status.sh (BR_LIST_CMD, BR_BLOCKED_CMD, MUXA_WHO_CMD,
# CP_JOBS_FILE). Run from the command-post repo: test/threads.sh
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

assert_py() {
  local label="$1" script="$2" payload="$3"
  if printf '%s' "$payload" | python3 -c "$script"; then
    ok "$label"
  else
    fail "$label"
  fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-threads.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
mkdir -p "$CP_HOME/state" "$TMP/wt-a" "$TMP/wt-b"

# origin-b's fields are the leak canaries: a distinctive title, a branch, and a
# PR URL that must never appear in origin-a's view or outbound log.
export B_TITLE="Beta secret refactor"
export B_PR="https://github.com/acme/widgets/pull/909"

printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$CP_JOBS_FILE"
printf 'job-a\tworker-a\t%s\tjob-a\t2026-08-24T16:00:00Z\t\torigin-a\n' "$TMP/wt-a" >> "$CP_JOBS_FILE"
printf 'job-b\tworker-b\t%s\tjob-b-branch\t2026-08-24T15:00:00Z\t2026-08-24T15:30:00Z\torigin-b\n' "$TMP/wt-b" >> "$CP_JOBS_FILE"
printf 'job-terminal\tworker-t\t%s\tjob-terminal\t2026-08-24T14:00:00Z\t\tterminal\n' "$TMP/wt-a" >> "$CP_JOBS_FILE"
printf 'job-legacy\tworker-l\t%s\tjob-legacy\n' "$TMP/wt-a" >> "$CP_JOBS_FILE"

cat > "$TMP/br-list.json" <<EOF
{"issues":[
  {"id":"job-a","title":"Alpha widget","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T16:05:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-b","title":"$B_TITLE ($B_PR)","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T15:35:00Z","labels":["project:demo","delivery:pr"]},
  {"id":"job-terminal","title":"Terminal chore","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T14:05:00Z","labels":["project:demo"]},
  {"id":"job-legacy","title":"Legacy row","status":"in_progress","priority":2,"issue_type":"task","updated_at":"2026-08-24T13:05:00Z","labels":["project:demo"]}
],"total":4,"limit":0,"offset":0,"has_more":false}
EOF

# job-a is br dep-blocked by job-b, which lives in another origin.
cat > "$TMP/br-blocked.json" <<'EOF'
{"issues":[
  {"id":"job-a","title":"Alpha widget","status":"in_progress","updated_at":"2026-08-24T16:05:00Z","labels":["project:demo"],"blocked_by_count":1,"blocked_by":["job-b"]}
],"total":1,"limit":0,"offset":0,"has_more":false}
EOF

cat > "$TMP/br-list-stub.sh" <<EOF
#!/bin/sh
set -eu
case "\$*" in
  *"--limit 0"*) ;;
  *) echo "stub: missing --limit 0" >&2; exit 2 ;;
esac
case "\$*" in
  *"-s closed"*) printf '[]\n'; exit 0 ;;
esac
cat "$TMP/br-list.json"
EOF
cat > "$TMP/br-blocked-stub.sh" <<EOF
#!/bin/sh
set -eu
case "\$*" in
  *"--limit 0"*) ;;
  *) echo "stub: missing --limit 0" >&2; exit 2 ;;
esac
cat "$TMP/br-blocked.json"
EOF
chmod +x "$TMP/br-list-stub.sh" "$TMP/br-blocked-stub.sh"
export BR_LIST_CMD="$TMP/br-list-stub.sh"
export BR_BLOCKED_CMD="$TMP/br-blocked-stub.sh"

# --- bind ------------------------------------------------------------------
"$CP" threads bind origin-a channel=C0123ABCDEF thread_ts=1712345678.000100 2>/dev/null
"$CP" threads bind origin-b channel=C0123ABCDEG thread_ts=1712345679.000100 2>/dev/null
assert_py "threads list --json returns both bindings" '
import json, sys
rows = {r["id"]: r for r in json.load(sys.stdin)}
assert set(rows) == {"origin-a", "origin-b"}, rows
assert rows["origin-a"]["channel"] == "C0123ABCDEF", rows
assert rows["origin-a"]["thread_ts"] == "1712345678.000100", rows
assert rows["origin-a"]["bound_at"], rows
' "$("$CP" threads list --json)"

if [[ -f "$CP_HOME/state/threads.tsv" ]]; then
  ok "bind writes state/threads.tsv"
else
  fail "bind writes state/threads.tsv"
fi

expect_rc_msg 1 "can never be bound" "bind refuses origin=terminal" \
  "$CP" threads bind terminal channel=C0123ABCDEF thread_ts=1712345678.000100
expect_rc_msg 1 "already bound" "bind refuses a second thread for one origin" \
  "$CP" threads bind origin-a channel=C0123ABCDEH thread_ts=1712345678.000200
expect_rc_msg 1 "already bound to origin" "bind refuses two origins on one thread" \
  "$CP" threads bind origin-c channel=C0123ABCDEF thread_ts=1712345678.000100
expect_rc_msg 1 "invalid thread_ts" "bind refuses a non-Slack thread_ts" \
  "$CP" threads bind origin-c channel=C0123ABCDEF thread_ts=not-a-ts
expect_rc_msg 1 "invalid channel" "bind refuses a malformed channel id" \
  "$CP" threads bind origin-c channel="C 123" thread_ts=1712345678.000300
expect_rc_msg 1 "invalid origin id" "bind refuses whitespace in the origin id" \
  "$CP" threads bind "bad origin" channel=C0123ABCDEF thread_ts=1712345678.000300
expect_rc_msg 2 "unknown field" "bind refuses unknown fields" \
  "$CP" threads bind origin-c channel=C0123ABCDEF thread_ts=1712345678.000300 text=hello

# --- events: isolation by construction -------------------------------------
EVENTS_A_JSON="$("$CP" threads events origin-a --json 2>/dev/null)"
assert_py "events origin-a carries only origin-a's job" '
import json, sys
evs = json.load(sys.stdin)
assert evs, evs
assert {e["br_id"] for e in evs} == {"job-a"}, evs
assert {e["origin"] for e in evs} == {"origin-a"}, evs
assert {e["kind"] for e in evs} == {"dispatched", "blocked"}, evs
' "$EVENTS_A_JSON"

assert_py "events origin-a leaks no origin-b id, title, branch, or PR URL" '
import json, sys, os
raw = sys.stdin.read()
for needle in ("job-b", os.environ["B_TITLE"], "job-b-branch", os.environ["B_PR"], "worker-b"):
    assert needle not in raw, (needle, raw)
' "$EVENTS_A_JSON"

EVENTS_A_TABLE="$("$CP" threads events origin-a 2>/dev/null)"
assert_py "events origin-a human table leaks nothing from origin-b" '
import sys, os
text = sys.stdin.read()
for needle in ("job-b", os.environ["B_TITLE"], "job-b-branch", os.environ["B_PR"]):
    assert needle not in text, (needle, text)
assert "job-a" in text, text
' "$EVENTS_A_TABLE"

expect_rc_msg 0 "carry no origin — dropped" "events reports ledger rows with no origin as dropped" \
  "$CP" threads events origin-a

assert_py "events drops the no-origin row instead of routing it" '
import json, sys
evs = json.load(sys.stdin)
assert all(e["br_id"] != "job-legacy" for e in evs), evs
' "$EVENTS_A_JSON"

assert_py "cross-origin br dep blocker is redacted to id=null title=null" '
import json, sys
evs = json.load(sys.stdin)
b = next(e for e in evs if e["kind"] == "blocked")
assert b["blocked_by"] == [{"id": None, "title": None}], b
' "$EVENTS_A_JSON"

EVENTS_B_JSON="$("$CP" threads events origin-b --json 2>/dev/null)"
assert_py "events origin-b sees its own reported event and no origin-a job" '
import json, sys
evs = json.load(sys.stdin)
assert {e["br_id"] for e in evs} == {"job-b"}, evs
assert "reported" in {e["kind"] for e in evs}, evs
raw = json.dumps(evs)
assert "job-a" not in raw and "Alpha widget" not in raw, raw
' "$EVENTS_B_JSON"

expect_rc_msg 1 "terminal dispatch" "events refuses the terminal origin" \
  "$CP" threads events terminal

# --- same-origin blocker keeps its name ------------------------------------
cat > "$TMP/br-blocked-same.json" <<'EOF'
{"issues":[
  {"id":"job-a","title":"Alpha widget","status":"in_progress","updated_at":"2026-08-24T16:05:00Z","labels":["project:demo"],"blocked_by_count":1,"blocked_by":["job-a2"]}
],"total":1,"limit":0,"offset":0,"has_more":false}
EOF
cat > "$TMP/br-list-same.json" <<'EOF'
{"issues":[
  {"id":"job-a","title":"Alpha widget","status":"in_progress","updated_at":"2026-08-24T16:05:00Z","labels":["project:demo"]},
  {"id":"job-a2","title":"Alpha helper","status":"in_progress","updated_at":"2026-08-24T16:04:00Z","labels":["project:demo"]}
],"total":2,"limit":0,"offset":0,"has_more":false}
EOF
printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$TMP/jobs-same.tsv"
printf 'job-a\tworker-a\t%s\tjob-a\t2026-08-24T16:00:00Z\t\torigin-a\n' "$TMP/wt-a" >> "$TMP/jobs-same.tsv"
printf 'job-a2\tworker-a2\t%s\tjob-a2\t2026-08-24T15:59:00Z\t\torigin-a\n' "$TMP/wt-a" >> "$TMP/jobs-same.tsv"
cat > "$TMP/br-list-same-stub.sh" <<EOF
#!/bin/sh
set -eu
case "\$*" in
  *"-s closed"*) printf '[]\n'; exit 0 ;;
esac
cat "$TMP/br-list-same.json"
EOF
cat > "$TMP/br-blocked-same-stub.sh" <<EOF
#!/bin/sh
set -eu
cat "$TMP/br-blocked-same.json"
EOF
chmod +x "$TMP/br-list-same-stub.sh" "$TMP/br-blocked-same-stub.sh"
SAME_JSON="$(
  CP_JOBS_FILE="$TMP/jobs-same.tsv" \
  BR_LIST_CMD="$TMP/br-list-same-stub.sh" \
  BR_BLOCKED_CMD="$TMP/br-blocked-same-stub.sh" \
  "$CP" threads events origin-a --json 2>/dev/null
)"
assert_py "same-origin blocker keeps id and title (redaction is not blanket)" '
import json, sys
evs = json.load(sys.stdin)
b = next(e for e in evs if e["kind"] == "blocked")
assert b["blocked_by"] == [{"id": "job-a2", "title": "Alpha helper"}], b
' "$SAME_JSON"

SAME_TEXT="$(
  CP_JOBS_FILE="$TMP/jobs-same.tsv" \
  BR_LIST_CMD="$TMP/br-list-same-stub.sh" \
  BR_BLOCKED_CMD="$TMP/br-blocked-same-stub.sh" \
  "$CP" relay render --br-id job-a --kind blocked 2>/dev/null
)"
if printf '%s\n' "$SAME_TEXT" | grep -F -q 'job-a2 (Alpha helper)'; then
  ok "relay render names a same-origin blocker"
else
  fail "relay render names a same-origin blocker (got: $SAME_TEXT)"
fi

# --- render ----------------------------------------------------------------
RENDER_DISPATCHED="$("$CP" relay render --br-id job-a --kind dispatched 2>/dev/null)"
if [[ "$RENDER_DISPATCHED" == *"job-a"* && "$RENDER_DISPATCHED" == *"Alpha widget"* ]]; then
  ok "relay render dispatched uses the templated event text"
else
  fail "relay render dispatched uses the templated event text (got: $RENDER_DISPATCHED)"
fi

RENDER_BLOCKED="$("$CP" relay render --br-id job-a --kind blocked 2>/dev/null)"
if [[ "$RENDER_BLOCKED" == *"another job"* ]] \
  && ! printf '%s' "$RENDER_BLOCKED" | grep -F -q -e "job-b" -e "$B_TITLE" -e "$B_PR"; then
  ok "relay render blocked says \"another job\" and names no foreign blocker"
else
  fail "relay render blocked says \"another job\" and names no foreign blocker (got: $RENDER_BLOCKED)"
fi

assert_py "relay render --json carries origin, channel, thread_ts, and text" '
import json, sys
d = json.load(sys.stdin)
assert d["origin"] == "origin-a", d
assert d["channel"] == "C0123ABCDEF", d
assert d["thread_ts"] == "1712345678.000100", d
assert d["br_id"] == "job-a" and d["kind"] == "dispatched", d
assert d["text"], d
' "$("$CP" relay render --br-id job-a --kind dispatched --json 2>/dev/null)"

expect_rc_msg 1 "no runtime row" "relay refuses an unknown br id" \
  "$CP" relay render --br-id job-nope --kind dispatched
expect_rc_msg 1 "has no origin" "relay refuses a ledger row with no origin" \
  "$CP" relay render --br-id job-legacy --kind dispatched
expect_rc_msg 1 "dispatched from the terminal" "relay refuses a terminal-dispatched job" \
  "$CP" relay render --br-id job-terminal --kind dispatched
expect_rc_msg 1 "no reported event" "relay refuses a kind the ledger has no event for" \
  "$CP" relay render --br-id job-a --kind reported
expect_rc_msg 2 "unknown --kind" "relay refuses an unknown event kind" \
  "$CP" relay render --br-id job-a --kind gossip

# unbound origin: the row has an origin, but nothing to post it to
printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$TMP/jobs-unbound.tsv"
printf 'job-u\tworker-u\t%s\tjob-u\t2026-08-24T16:00:00Z\t\torigin-unbound\n' "$TMP/wt-a" >> "$TMP/jobs-unbound.tsv"
cat > "$TMP/br-list-u-stub.sh" <<'EOF'
#!/bin/sh
set -eu
case "$*" in
  *"-s closed"*) printf '[]\n'; exit 0 ;;
esac
printf '[{"id":"job-u","title":"Unbound job","status":"in_progress","updated_at":"2026-08-24T16:05:00Z","labels":[]}]\n'
EOF
cat > "$TMP/br-blocked-empty-stub.sh" <<'EOF'
#!/bin/sh
printf '[]\n'
EOF
chmod +x "$TMP/br-list-u-stub.sh" "$TMP/br-blocked-empty-stub.sh"
expect_rc_msg 1 "not bound to a thread" "relay refuses an origin with no bound thread" \
  env CP_JOBS_FILE="$TMP/jobs-unbound.tsv" BR_LIST_CMD="$TMP/br-list-u-stub.sh" \
  BR_BLOCKED_CMD="$TMP/br-blocked-empty-stub.sh" "$CP" relay render --br-id job-u --kind dispatched

assert_py "refusals are logged locally to state/threads/dropped.log" '
import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
by_id = {d["br_id"]: d for d in lines}
assert "has no origin" in by_id["job-legacy"]["reason"], by_id["job-legacy"]
assert by_id["job-u"]["reason"] == "origin not bound to a thread", by_id["job-u"]
assert by_id["job-u"]["origin"] == "origin-unbound", by_id["job-u"]
' "$(cat "$CP_HOME/state/threads/dropped.log")"

# --- a malformed origin is never turned into a path ------------------------
printf '#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n' > "$TMP/jobs-evil.tsv"
printf 'job-e\tworker-e\t%s\tjob-e\t2026-08-24T16:00:00Z\t\t../../escape\n' "$TMP/wt-a" >> "$TMP/jobs-evil.tsv"
expect_rc_msg 1 "malformed origin" "relay refuses a hand-edited traversal origin" \
  env CP_JOBS_FILE="$TMP/jobs-evil.tsv" BR_LIST_CMD="$TMP/br-list-u-stub.sh" \
  BR_BLOCKED_CMD="$TMP/br-blocked-empty-stub.sh" "$CP" relay render --br-id job-e --kind dispatched

expect_rc_msg 1 "invalid origin" "jobs add refuses an origin that is not br-id shaped" \
  env CP_JOBS_FILE="$TMP/jobs-evil.tsv" "$CP" jobs add job-f worker=w worktree="$TMP/wt-a" origin=../escape

# --- post: no tokens -------------------------------------------------------
expect_rc_msg 3 "not configured" "relay post without tokens exits 3 and posts nothing" \
  "$CP" relay post --br-id job-a --kind dispatched
if [[ ! -e "$CP_HOME/state/threads/origin-a.out.log" ]]; then
  ok "relay post without tokens writes no outbound log"
else
  fail "relay post without tokens writes no outbound log"
fi

# --- post: local stub API --------------------------------------------------
cat > "$TMP/slack-stub.py" <<'PY'
import json, sys, http.server
OUT = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('content-length', 0))
        body = self.rfile.read(n).decode()
        with open(OUT, 'a') as f:
            f.write(json.dumps({
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "body": json.loads(body),
            }) + "\n")
        self.send_response(200)
        self.send_header('content-type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"ok":true,"ts":"1712345680.000200"}')
    def log_message(self, *a):
        pass
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
STUB_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 "$TMP/slack-stub.py" "$STUB_PORT" "$TMP/posts.jsonl" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true; wait "$STUB_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do
  python3 -c "import socket,sys; s=socket.socket();
sys.exit(0 if s.connect_ex(('127.0.0.1', $STUB_PORT)) == 0 else 1)" && break
  sleep 0.1
done
export CP_SLACK_API_BASE="http://127.0.0.1:$STUB_PORT"

mkdir -p "$CP_HOME/state/slack"
TOKENS="$CP_HOME/state/slack/tokens.env"
printf 'SLACK_BOT_TOKEN=xoxb-test-123\nSLACK_APP_TOKEN=xapp-test-456\n' > "$TOKENS"
chmod 600 "$TOKENS"

expect_rc_msg 0 "" "relay post with tokens posts the rendered event" \
  "$CP" relay post --br-id job-a --kind dispatched

assert_py "post hits chat.postMessage in the bound thread with the bot token" '
import json, sys
recs = [json.loads(l) for l in sys.stdin if l.strip()]
assert len(recs) == 1, recs
r = recs[0]
assert r["path"] == "/chat.postMessage", r
assert r["auth"] == "Bearer xoxb-test-123", r
assert r["body"]["channel"] == "C0123ABCDEF", r
assert r["body"]["thread_ts"] == "1712345678.000100", r
assert "job-a" in r["body"]["text"], r
' "$(cat "$TMP/posts.jsonl")"

assert_py "posted text carries nothing from origin-b" '
import json, sys, os
recs = [json.loads(l) for l in sys.stdin if l.strip()]
text = " ".join(r["body"]["text"] for r in recs)
for needle in ("job-b", os.environ["B_TITLE"], "job-b-branch", os.environ["B_PR"]):
    assert needle not in text, (needle, text)
' "$(cat "$TMP/posts.jsonl")"

OUT_LOG="$CP_HOME/state/threads/origin-a.out.log"
assert_py "outbound log records origin provenance for every post" '
import json, sys
lines = [json.loads(l) for l in sys.stdin if l.strip()]
assert lines, lines
for d in lines:
    assert d["origin"] == "origin-a", d
    assert d["channel"] == "C0123ABCDEF", d
    assert d["thread_ts"] == "1712345678.000100", d
    assert d["br_id"] == "job-a", d
    assert d["at"], d
' "$(cat "$OUT_LOG")"

if grep -F -q -e "job-b" -e "$B_TITLE" -e "job-b-branch" -e "$B_PR" "$OUT_LOG"; then
  fail "isolation: origin-a outbound log holds a foreign br id, label, branch, or PR URL"
else
  ok "isolation: origin-a outbound log holds no foreign br id, label, branch, or PR URL"
fi

# Terminal dispatch never posts, even with tokens present.
POSTS_BEFORE="$(wc -l < "$TMP/posts.jsonl" | tr -d ' ')"
expect_rc_msg 1 "dispatched from the terminal" "terminal-origin job never posts even when configured" \
  "$CP" relay post --br-id job-terminal --kind dispatched
expect_rc_msg 1 "has no origin" "no-origin job never posts even when configured" \
  "$CP" relay post --br-id job-legacy --kind dispatched
POSTS_AFTER="$(wc -l < "$TMP/posts.jsonl" | tr -d ' ')"
if [[ "$POSTS_BEFORE" == "$POSTS_AFTER" ]]; then
  ok "refused events reach the Slack API zero times"
else
  fail "refused events reach the Slack API zero times ($POSTS_BEFORE -> $POSTS_AFTER)"
fi

expect_rc_msg 1 "only point at loopback" "the API base override cannot redirect the token off-host" \
  env CP_SLACK_API_BASE="https://evil.example.com/api" "$CP" relay post --br-id job-a --kind blocked

# --- token file hygiene ----------------------------------------------------
chmod 644 "$TOKENS"
expect_rc_msg 1 "group/world readable" "relay refuses a world-readable token file" \
  "$CP" relay post --br-id job-a --kind blocked
chmod 600 "$TOKENS"

printf 'SLACK_BOT_TOKEN=xoxp-user-token\n' > "$TMP/bad-tokens.env"
chmod 600 "$TMP/bad-tokens.env"
expect_rc_msg 1 "not a bot token" "relay refuses a non-bot token" \
  env CP_SLACK_TOKENS="$TMP/bad-tokens.env" "$CP" relay post --br-id job-a --kind blocked

printf 'SLACK_APP_TOKEN=xapp-only\n' > "$TMP/no-bot.env"
chmod 600 "$TMP/no-bot.env"
expect_rc_msg 1 "no SLACK_BOT_TOKEN" "relay refuses a token file with no bot token" \
  env CP_SLACK_TOKENS="$TMP/no-bot.env" "$CP" relay post --br-id job-a --kind blocked

assert_py "relay status --json reports configured state and bound thread count" '
import json, sys
d = json.load(sys.stdin)
assert d["slack"] == "configured", d
assert d["threads"] == 2, d
assert "not implemented" in d["inbound"], d
' "$("$CP" relay status --json)"

assert_py "relay status --json reports not configured when the token file is absent" '
import json, sys
d = json.load(sys.stdin)
assert d["slack"] == "not configured", d
' "$(CP_SLACK_TOKENS="$TMP/absent.env" "$CP" relay status --json)"

# --- templates -------------------------------------------------------------
printf 'dispatched\tCustom {{br_id}} for {{title}}\n' > "$TMP/tpl-ok.tsv"
CUSTOM="$(CP_THREAD_EVENTS_TSV="$TMP/tpl-ok.tsv" "$CP" relay render --br-id job-a --kind dispatched 2>/dev/null)"
if [[ "$CUSTOM" == "Custom job-a for Alpha widget" ]]; then
  ok "templates: CP_HOME template file overrides the built-in text"
else
  fail "templates: CP_HOME template file overrides the built-in text (got: $CUSTOM)"
fi

printf 'dispatched\tLeaky {{everything}}\n' > "$TMP/tpl-bad.tsv"
expect_rc_msg 1 "unsubstituted" "templates: an unknown placeholder is a fail-closed render error" \
  env CP_THREAD_EVENTS_TSV="$TMP/tpl-bad.tsv" "$CP" relay render --br-id job-a --kind dispatched

printf 'gossip\tanything\n' > "$TMP/tpl-kind.tsv"
expect_rc_msg 1 "unknown event kind" "templates: an unknown event kind is refused" \
  env CP_THREAD_EVENTS_TSV="$TMP/tpl-kind.tsv" "$CP" relay render --br-id job-a --kind dispatched

printf 'dispatched\n' > "$TMP/tpl-shape.tsv"
expect_rc_msg 1 "expected kind" "templates: a line with no tab is refused" \
  env CP_THREAD_EVENTS_TSV="$TMP/tpl-shape.tsv" "$CP" relay render --br-id job-a --kind dispatched

TRACKED_TPL="$ROOT/templates/thread-events.tsv"
if [[ -f "$TRACKED_TPL" ]] && awk -F'\t' '
  /^#/ || NF == 0 { next }
  { if (NF < 2 || $2 == "") exit 1
    if ($1 != "dispatched" && $1 != "reported" && $1 != "blocked" && $1 != "closed") exit 1
    seen++ }
  END { exit(seen > 0 ? 0 : 1) }
' "$TRACKED_TPL"; then
  ok "tracked templates/thread-events.tsv is tab-separated with known kinds only"
else
  fail "tracked templates/thread-events.tsv is tab-separated with known kinds only"
fi

if grep -n -E '\{\{(pr|status_block|origin_[a-z]+)\}\}' "$TRACKED_TPL" >/dev/null; then
  fail "tracked template uses a placeholder the renderer does not substitute"
else
  ok "tracked template uses only substitutable placeholders"
fi

# --- threads status (origin-filtered) --------------------------------------
cat > "$TMP/who.json" <<EOF
[
  {"name":"root-pane","id":"r1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"$CP_HOME"},
  {"name":"worker-a","id":"w1","parent":"root-pane","kind":"cursor","state":"idle","pane":"%2","session":null,"cwd":"$TMP/wt-a"},
  {"name":"worker-b","id":"w2","parent":"root-pane","kind":"cursor","state":"busy","pane":"%3","session":null,"cwd":"$TMP/wt-b"}
]
EOF
cat > "$TMP/broker.json" <<'EOF'
{"ok":true,"pid":1,"queued":0,"done":0,"failed":0,"socket":"/tmp/fake.sock","drawing":[]}
EOF
export MUXA_WHO_CMD="cat $TMP/who.json"
export MUXA_BROKER_CMD="cat $TMP/broker.json"
export CP_STATUS_NOW="2026-08-24T16:10:00Z"

STATUS_A="$("$CP" threads status origin-a --json 2>/dev/null)"
assert_py "threads status ID renders the origin-filtered status and nothing else" '
import json, sys, os
d = json.load(sys.stdin)
assert d.get("origin") == "origin-a", d
raw = json.dumps(d)
for needle in ("job-b", os.environ["B_TITLE"], "job-b-branch", os.environ["B_PR"], "worker-b"):
    assert needle not in raw, (needle, raw)
' "$STATUS_A"

expect_rc_msg 1 "no thread bound" "threads status refuses an unbound origin" \
  "$CP" threads status origin-nope
expect_rc_msg 1 "terminal dispatch" "threads status refuses the terminal origin" \
  "$CP" threads status terminal

# --- dispatch --origin -----------------------------------------------------
expect_rc_msg 1 "not bound to a thread" "dispatch refuses an unbound --origin before taking a lease" \
  "$CP" dispatch --project no-such-project --br-id job-x --origin origin-nope
expect_rc_msg 1 "invalid origin id" "dispatch refuses a malformed --origin before taking a lease" \
  "$CP" dispatch --project no-such-project --br-id job-x --origin " "

# --- unbind / log ----------------------------------------------------------
LOG_PATH="$("$CP" threads log origin-a)"
if [[ "$LOG_PATH" == *"/state/threads/origin-a.out.log" && -f "$LOG_PATH" ]]; then
  ok "threads log prints the outbound log path"
else
  fail "threads log prints the outbound log path (got: $LOG_PATH)"
fi

BEFORE_JOBS="$(cat "$CP_JOBS_FILE")"
"$CP" threads unbind origin-b 2>/dev/null
assert_py "unbind drops only that binding" '
import json, sys
rows = [r["id"] for r in json.load(sys.stdin)]
assert rows == ["origin-a"], rows
' "$("$CP" threads list --json)"
expect_rc_msg 1 "no thread bound" "unbind refuses an unknown origin" \
  "$CP" threads unbind origin-b
if [[ "$BEFORE_JOBS" == "$(cat "$CP_JOBS_FILE")" ]]; then
  ok "threads and relay never mutate state/jobs.tsv"
else
  fail "threads and relay never mutate state/jobs.tsv"
fi

# --- doctor: advisory, never a failure -------------------------------------
DOCTOR_JSON="$(CP_SLACK_TOKENS="$TMP/absent.env" "$CP" doctor --json 2>/dev/null || true)"
assert_py "doctor reports missing Slack tokens as advisory" '
import json, sys
d = json.load(sys.stdin)
s = d["slack"]
assert s["state"] == "not configured", s
assert s["advisory"] is True, s
assert not any(m.get("kind", "").startswith("slack") for m in d.get("missing") or []), d.get("missing")
' "$DOCTOR_JSON"

assert_py "doctor derives the status --serve port from the home" '
import json, sys
d = json.load(sys.stdin)
p = d["status_port"]
assert 8765 <= p <= 9764, p
' "$DOCTOR_JSON"

assert_py "CP_STATUS_PORT overrides the derived port in doctor" '
import json, sys
d = json.load(sys.stdin)
assert d["status_port"] == 9999, d["status_port"]
' "$(CP_STATUS_PORT=9999 "$CP" doctor --json 2>/dev/null || true)"

cat > "$TMP/who-two-homes.json" <<EOF
[
  {"name":"root-here","id":"r1","parent":null,"kind":"claude","state":"busy","pane":"%1","session":null,"cwd":"$CP_HOME"},
  {"name":"root-elsewhere","id":"r2","parent":null,"kind":"claude","state":"busy","pane":"%9","session":null,"cwd":"$TMP/other-home"}
]
EOF
mkdir -p "$TMP/other-home"
DOCTOR_TWO="$(MUXA_WHO_CMD="cat $TMP/who-two-homes.json" "$CP" doctor --json 2>/dev/null || true)"
assert_py "doctor notices another CP_HOME parent on this muxa server" '
import json, sys
d = json.load(sys.stdin)
others = {o["alias"] for o in d["other_parents"]}
assert others == {"root-elsewhere"}, d["other_parents"]
' "$DOCTOR_TWO"

DOCTOR_TEXT="$(MUXA_WHO_CMD="cat $TMP/who-two-homes.json" "$CP" doctor 2>/dev/null || true)"
if printf '%s\n' "$DOCTOR_TEXT" | grep -F -q "other root on this muxa server: root-elsewhere"; then
  ok "doctor human output names the other home's root pane"
else
  fail "doctor human output names the other home's root pane"
fi

STATUS_PORT_ONE="$("$CP" doctor --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status_port"])' || true)"
STATUS_PORT_TWO="$(CP_HOME="$TMP/other-home" "$CP" doctor --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["status_port"])' || true)"
if [[ -n "$STATUS_PORT_ONE" && -n "$STATUS_PORT_TWO" && "$STATUS_PORT_ONE" != "$STATUS_PORT_TWO" ]]; then
  ok "two homes derive different --serve ports (no silent 8765 clash)"
else
  fail "two homes derive different --serve ports (got $STATUS_PORT_ONE and $STATUS_PORT_TWO)"
fi

printf '\n%d test(s); %d failed\n' "$n" "$failed"
[[ "$failed" -eq 0 ]]
