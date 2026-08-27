#!/usr/bin/env bash
# Unit tests for bin/cmdp gate (isolated temp br db; reviewer stubbed via CP_GATE_CMD).
# Run from the command-post repo: test/gate.sh
set -euo pipefail

# BR: binary for fresh-init tests (artifact.sh, gate.sh). Default = PATH `br`.
# Override to exercise 0.5.2 without swapping PATH:
#   BR=$HOME/.local/bin/br-0.5.2.parked test/gate.sh
BR="${BR:-br}"
command -v "$BR" >/dev/null || { echo "br not found (set BR to an executable)" >&2; exit 2; }
BR_BIN="$(command -v "$BR")"
export PATH="$(dirname "$BR_BIN"):$PATH"

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

if ! command -v "$BR" >/dev/null 2>&1; then
  printf 'br not on PATH (needed for gate tests)\n' >&2
  exit 2
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-gate.XXXXXX")"
ORIG_PATH="$PATH"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME"

TOKEN="SECRET_BODY_TOKEN_gate_vet"
printf 'Goal: test artifact\n%s\n' "$TOKEN" > "$TMP/src.md"

write_stub() {
  local path="$1" body="$2"
  printf '%s\n' '#!/bin/sh' > "$path"
  printf 'cat >"%s/last-prompt"\n' "$TMP" >> "$path"
  printf 'echo x >>"%s/runs"\n' "$TMP" >> "$path"
  printf '%s\n' "cat <<'V'" >> "$path"
  printf '%s\n' "$body" >> "$path"
  printf '%s\n' "V" >> "$path"
  chmod +x "$path"
}

PASS_VERDICT='verdict: pass
reasons:
- complete and scored
flags:
destructive_scope: no
scope_growth: no
blocking_unknowns: no'

REVISE_VERDICT='verdict: revise
reasons:
- file list incomplete
flags:
destructive_scope: no
scope_growth: no
blocking_unknowns: no
revisions:
- name every file'

FLAG_VERDICT='verdict: pass
reasons:
- reviewer said pass
flags:
destructive_scope: yes
scope_growth: no
blocking_unknowns: no'

write_stub "$TMP/pass.sh" "$PASS_VERDICT"
write_stub "$TMP/revise.sh" "$REVISE_VERDICT"
write_stub "$TMP/flag.sh" "$FLAG_VERDICT"
printf '%s\n' '#!/bin/sh' > "$TMP/malformed.sh"
printf 'cat >/dev/null\n' >> "$TMP/malformed.sh"
printf 'echo x >>"%s/runs"\n' "$TMP" >> "$TMP/malformed.sh"
printf 'echo "not a structured verdict"\n' >> "$TMP/malformed.sh"
chmod +x "$TMP/malformed.sh"

# missing artifact (no .beads yet, then with issue but no artifact:v1)
expect_exit 1 "gate fails when HOME has no .beads" "$CP" gate t-one
export CP_GATE_CMD="$TMP/pass.sh"
expect_exit 1 "gate fails when HOME has no .beads even with stub" "$CP" gate t-one
if [[ ! -e "$CP_HOME/.beads" ]]; then
  ok "missing .beads does not auto-init a tracker"
else
  fail "missing .beads does not auto-init a tracker"
fi
if [[ ! -f "$TMP/runs" ]]; then
  ok "reviewer is not invoked when HOME has no .beads"
else
  fail "reviewer is not invoked when HOME has no .beads"
fi

(
  cd "$CP_HOME"
  "$BR" init --prefix t >/dev/null
)
DB="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CP_HOME/.beads/beads.db")"
ID="$("$BR" --db "$DB" create "gate-test" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

rm -f "$TMP/runs" "$TMP/last-prompt"
export CP_GATE_CMD="$TMP/pass.sh"
rc=0
err="$("$CP" gate "$ID" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 1 ]] && printf '%s\n' "$err" | grep -q 'cannot gate'; then
  ok "missing artifact is fail-closed with a distinct message"
else
  fail "missing artifact is fail-closed with a distinct message (rc=$rc err=$(printf %q "$err"))"
fi
if [[ ! -f "$TMP/runs" ]]; then
  ok "reviewer is not invoked when no artifact exists"
else
  fail "reviewer is not invoked when no artifact exists"
fi

"$CP" artifact add "$ID" "$TMP/src.md" >/dev/null

# BR_SHOW_CMD would trip require_br_issue; gate must not call br show.
export BR_SHOW_CMD=false
rm -f "$TMP/runs" "$TMP/last-prompt"
rc=0
out="$("$CP" gate "$ID")" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "pass exits 0"
else
  fail "pass exits 0 (got $rc out=$(printf %q "$out"))"
fi
if printf '%s\n' "$out" | TOKEN="$TOKEN" ID="$ID" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
assert d["br_id"] == os.environ["ID"]
assert d["verdict"] == "pass"
assert d["attempt"] == 1
assert d["flags"] == {"destructive_scope": "no", "scope_growth": "no", "blocking_unknowns": "no"}
assert d["reasons"] == ["complete and scored"]
assert d["cause"] is None
assert "revisions" not in d
assert os.environ["TOKEN"] not in json.dumps(d)
'; then
  ok "pass prints {br_id, verdict, attempt, flags, reasons} JSON (no revisions)"
else
  fail "pass prints JSON (got $out)"
fi
if printf '%s\n' "$out" | grep -F -q "$TOKEN"; then
  fail "pass stdout does not include the artifact body"
else
  ok "pass stdout does not include the artifact body"
fi
if [[ -f "$TMP/last-prompt" ]] && grep -q 'You are a fresh-context reviewer' "$TMP/last-prompt" && grep -F -q "$TOKEN" "$TMP/last-prompt"; then
  ok "reviewer stdin is the rubric followed by the artifact"
else
  fail "reviewer stdin is the rubric followed by the artifact"
fi
if [[ -f "$TMP/runs" ]] && [[ "$(wc -l < "$TMP/runs" | tr -d ' ')" -eq 1 ]]; then
  ok "pass invokes the reviewer once"
else
  fail "pass invokes the reviewer once"
fi

comments="$("$BR" --db "$DB" comments list "$ID" --json)"
if printf '%s\n' "$comments" | TOKEN="$TOKEN" python3 -c '
import json, os, sys
comments = json.load(sys.stdin)
gates = [c for c in comments if isinstance(c, dict) and str(c.get("text","")).splitlines()[:1] == ["gate:v1"]]
assert len(gates) == 1
text = gates[0]["text"]
assert "attempt: 1" in text
assert "verdict: pass" in text
assert os.environ["TOKEN"] not in text
'; then
  ok "pass records a short gate:v1 comment without the artifact body"
else
  fail "pass records a short gate:v1 comment without the artifact body"
fi
unset BR_SHOW_CMD

# revise
ID2="$("$BR" --db "$DB" create "gate-revise" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID2" "$TMP/src.md" >/dev/null
export CP_GATE_CMD="$TMP/revise.sh"
rm -f "$TMP/runs"
rc=0
out="$("$CP" gate "$ID2")" || rc=$?
if [[ "$rc" -eq 10 ]]; then
  ok "revise exits 10"
else
  fail "revise exits 10 (got $rc out=$(printf %q "$out"))"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "revise"
assert d["attempt"] == 1
assert d["reasons"] == ["file list incomplete"]
assert d["revisions"] == ["name every file"]
assert d["cause"] is None
'; then
  ok "revise JSON includes reasons and revisions"
else
  fail "revise JSON includes reasons and revisions (got $out)"
fi
comments="$("$BR" --db "$DB" comments list "$ID2" --json)"
if printf '%s\n' "$comments" | python3 -c '
import json, sys
comments = json.load(sys.stdin)
gates = [c for c in comments if str(c.get("text","")).splitlines()[:1] == ["gate:v1"]]
assert len(gates) == 1
assert "verdict: revise" in gates[0]["text"]
assert "revisions:" in gates[0]["text"]
'; then
  ok "revise comment includes revisions"
else
  fail "revise comment includes revisions"
fi

# revise → revise becomes escalate (one-revision cap)
rm -f "$TMP/runs"
rc=0
out="$("$CP" gate "$ID2")" || rc=$?
if [[ "$rc" -eq 20 ]]; then
  ok "second revise is escalate (attempt cap) exit 20"
else
  fail "second revise is escalate (attempt cap) exit 20 (got $rc out=$(printf %q "$out"))"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "escalate"
assert d["attempt"] == 2
assert d["cause"] == "policy"
assert any("attempt cap" in r for r in d["reasons"])
assert "revisions" not in d
'; then
  ok "capped run JSON is escalate with reasons, no revisions"
else
  fail "capped run JSON is escalate with reasons, no revisions (got $out)"
fi
comments="$("$BR" --db "$DB" comments list "$ID2" --json)"
if printf '%s\n' "$comments" | python3 -c '
import json, sys
comments = json.load(sys.stdin)
gates = [c["text"] for c in comments if str(c.get("text","")).splitlines()[:1] == ["gate:v1"]]
assert len(gates) == 2
assert any("attempt cap" in t for t in gates)
'; then
  ok "capped escalate records the attempt-cap reason"
else
  fail "capped escalate records the attempt-cap reason"
fi

# flag forces escalate even when reviewer said pass
ID3="$("$BR" --db "$DB" create "gate-flag" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID3" "$TMP/src.md" >/dev/null
export CP_GATE_CMD="$TMP/flag.sh"
rc=0
out="$("$CP" gate "$ID3")" || rc=$?
if [[ "$rc" -eq 20 ]]; then
  ok "flag=yes forces escalate exit 20"
else
  fail "flag=yes forces escalate exit 20 (got $rc out=$(printf %q "$out"))"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "escalate"
assert d["flags"]["destructive_scope"] == "yes"
assert d["attempt"] == 1
assert d["cause"] == "policy"
assert any("flag forced escalate" in r for r in d["reasons"])
assert "revisions" not in d
'; then
  ok "flag-forced JSON keeps the yes flag, reasons, and no revisions"
else
  fail "flag-forced JSON keeps the yes flag, reasons, and no revisions (got $out)"
fi

# malformed → retry → escalate
ID4="$("$BR" --db "$DB" create "gate-bad" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID4" "$TMP/src.md" >/dev/null
export CP_GATE_CMD="$TMP/malformed.sh"
rm -f "$TMP/runs"
rc=0
out="$("$CP" gate "$ID4")" || rc=$?
if [[ "$rc" -eq 20 ]]; then
  ok "malformed output retries then escalates exit 20"
else
  fail "malformed output retries then escalates exit 20 (got $rc out=$(printf %q "$out"))"
fi
if [[ -f "$TMP/runs" ]] && [[ "$(wc -l < "$TMP/runs" | tr -d ' ')" -eq 2 ]]; then
  ok "malformed output retries the reviewer once"
else
  fail "malformed output retries the reviewer once (runs=$(wc -l < "$TMP/runs" 2>/dev/null | tr -d ' '))"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "escalate"
assert d["attempt"] == 1
assert d["cause"] == "operational"
assert d["reasons"] == ["reviewer output unparseable after one retry"]
assert "revisions" not in d
'; then
  ok "malformed escalate JSON includes reasons, no revisions"
else
  fail "malformed escalate JSON includes reasons, no revisions (got $out)"
fi
comments="$("$BR" --db "$DB" comments list "$ID4" --json)"
if printf '%s\n' "$comments" | python3 -c '
import json, sys
comments = json.load(sys.stdin)
gates = [c["text"] for c in comments if str(c.get("text","")).splitlines()[:1] == ["gate:v1"]]
assert len(gates) == 1
assert "cause: operational" in gates[0]
'; then
  ok "first operational gate comment records cause: operational"
else
  fail "first operational gate comment records cause: operational"
fi

# repeated operational → operational_persistent (second gate run, same malformed stub)
rm -f "$TMP/runs"
rc=0
out="$("$CP" gate "$ID4")" || rc=$?
if [[ "$rc" -eq 20 ]]; then
  ok "repeated malformed escalates exit 20"
else
  fail "repeated malformed escalates exit 20 (got $rc out=$(printf %q "$out"))"
fi
if [[ -f "$TMP/runs" ]] && [[ "$(wc -l < "$TMP/runs" | tr -d ' ')" -eq 2 ]]; then
  ok "repeated operational still retries reviewer once per gate run"
else
  fail "repeated operational still retries reviewer once per gate run"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["verdict"] == "escalate"
assert d["attempt"] == 2
assert d["cause"] == "operational_persistent"
assert any("prior operational" in r for r in d["reasons"])
assert "revisions" not in d
'; then
  ok "repeated operational JSON is operational_persistent"
else
  fail "repeated operational JSON is operational_persistent (got $out)"
fi
comments="$("$BR" --db "$DB" comments list "$ID4" --json)"
if printf '%s\n' "$comments" | python3 -c '
import json, sys
comments = json.load(sys.stdin)
gates = [c["text"] for c in comments if str(c.get("text","")).splitlines()[:1] == ["gate:v1"]]
assert len(gates) == 2
assert "cause: operational_persistent" in gates[1]
'; then
  ok "repeated operational gate comment records cause: operational_persistent"
else
  fail "repeated operational gate comment records cause: operational_persistent"
fi

# operational after revise is still first operational (not persistent)
ID4B="$("$BR" --db "$DB" create "gate-bad-revise" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID4B" "$TMP/src.md" >/dev/null
export CP_GATE_CMD="$TMP/revise.sh"
"$CP" gate "$ID4B" >/dev/null || true
export CP_GATE_CMD="$TMP/malformed.sh"
rm -f "$TMP/runs"
out="$("$CP" gate "$ID4B")" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["attempt"] == 2
assert d["cause"] == "operational"
'; then
  ok "operational after revise stays operational not persistent"
else
  fail "operational after revise stays operational not persistent (got $out)"
fi

# bloated reviewer text is truncated so stdout JSON stays a few hundred words
BLOATED_REASON="$(python3 -c 'print(" ".join("word%d" % i for i in range(400)))')"
BLOATED_REV="$(python3 -c 'print(" ".join("rev%d" % i for i in range(200)))')"
write_stub "$TMP/bloated.sh" "verdict: revise
reasons:
- ${BLOATED_REASON}
flags:
destructive_scope: no
scope_growth: no
blocking_unknowns: no
revisions:
- ${BLOATED_REV}"
ID_BLOB="$("$BR" --db "$DB" create "gate-bloat" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID_BLOB" "$TMP/src.md" >/dev/null
export CP_GATE_CMD="$TMP/bloated.sh"
rc=0
out="$("$CP" gate "$ID_BLOB")" || rc=$?
if [[ "$rc" -eq 10 ]]; then
  ok "bloated revise still exits 10"
else
  fail "bloated revise still exits 10 (got $rc out=$(printf %q "$out"))"
fi
if printf '%s\n' "$out" | TOKEN="$TOKEN" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
assert d["verdict"] == "revise"
assert isinstance(d.get("reasons"), list) and d["reasons"]
assert isinstance(d.get("revisions"), list) and d["revisions"]
blob = json.dumps(d)
assert len(blob.split()) <= 300
assert "..." in blob
assert "word399" not in blob
assert "rev199" not in blob
assert os.environ["TOKEN"] not in blob
'; then
  ok "bloated revise JSON truncates reasons/revisions under the word cap"
else
  fail "bloated revise JSON truncates reasons/revisions under the word cap (got $out)"
fi

# --model is accepted (stub ignores it); usage
export CP_GATE_CMD="$TMP/pass.sh"
ID5="$("$BR" --db "$DB" create "gate-model" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID5" "$TMP/src.md" >/dev/null
expect_exit 0 "gate --model is accepted" "$CP" gate "$ID5" --model composer-2.5-fast
expect_exit 2 "gate without ID is usage" "$CP" gate
expect_exit 2 "unknown flag is usage" "$CP" gate --nope "$ID"

# missing agent without CP_GATE_CMD → exit 2 (no worker CLI on isolated PATH)
unset CP_GATE_CMD
ID6="$("$BR" --db "$DB" create "gate-noagent" -t task -p 2 --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
"$CP" artifact add "$ID6" "$TMP/src.md" >/dev/null
gate_isolated_path() {
  mkdir -p "$TMP/host"
  local c p
  for c in rm mkdir mktemp bash awk sed grep chmod printf python3 br dirname readlink pwd tr; do
    p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "$TMP/host/$c" ]] && ln -sf "$p" "$TMP/host/$c"
  done
  printf '%s' "$ORIG_PATH" | tr ':' '\n' | while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$d" in "$TMP/host"|"$TMP/shim") continue ;; esac
    [[ -x "$d/agent" || -x "$d/claude" || -x "$d/cursor-agent" ]] && continue
    printf '%s:' "$d"
  done | sed 's/:$//'
}
rc=0
err="$(env PATH="$TMP/host:$(gate_isolated_path)" "$CP" gate "$ID6" 2>&1 >/dev/null)" || rc=$?
if [[ "$rc" -eq 2 ]] && printf '%s\n' "$err" | grep -q "Install one of:"; then
  ok "gate without worker CLI exits 2 naming install targets"
else
  fail "gate missing worker CLI (rc=$rc err=$(printf %q "$err"))"
fi

# CP_GATE_CMD still wins when agent missing from PATH
export CP_GATE_CMD="$TMP/pass.sh"
rc=0
out="$("$CP" gate "$ID6")" || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "CP_GATE_CMD wins when agent is not required"
else
  fail "CP_GATE_CMD wins (rc=$rc out=$(printf %q "$out"))"
fi

export CP_GATE_CMD="$TMP/pass.sh"
help="$("$CP" gate --help 2>&1)" || true
if printf '%s\n' "$help" | grep -q 'does NOT close the issue or authorize implementation'; then
  ok "help states pass does not close or authorize implementation"
else
  fail "help states pass does not close or authorize implementation"
fi
if printf '%s\n' "$help" | grep -q 'cause is null on pass/revise' && printf '%s\n' "$help" | grep -q 'operational_persistent'; then
  ok "help documents cause on stdout JSON"
else
  fail "help documents cause on stdout JSON"
fi
if printf '%s\n' "$help" | grep -q 'ellipsis'; then
  ok "help documents truncation on stdout JSON"
else
  fail "help documents truncation on stdout JSON"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
