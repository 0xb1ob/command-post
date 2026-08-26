#!/usr/bin/env bash
# Real-br contract against committed schema-16 fixture (br 0.5.2 migrate path).
set -euo pipefail

# BR052: 0.5.2 binary for schema-16 mismatch + migrate (br-contract.sh only).
# Default matches the parked path used on this machine; CI must set BR052
# to a private copy of the v0.5.2 release asset (do not put it on PATH
# ahead of 0.2.19 until the live ledger is migrated).
BR052="${BR052:-$HOME/.local/bin/br-0.5.2.parked}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$ROOT/bin/cp"
FIX_SRC="$ROOT/test/fixtures/beads16"
OPEN_ID="t-z34"
PRE_TOTAL=53
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

if [[ ! -x "$BR052" ]]; then
  printf 'skip: BR052 not executable (%s)\n' "$BR052"
  exit 0
fi
if ! "$BR052" --version 2>/dev/null | grep -q '0.5.2'; then
  printf 'skip: BR052 is not br 0.5.2 (%s)\n' "$("$BR052" --version 2>/dev/null || echo missing)"
  exit 0
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-br-contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

cp -R "$FIX_SRC" "$TMP/beads16"
DB="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$TMP/beads16/.beads/beads.db")"

# --- SCHEMA_MISMATCH on schema-16 copy ---
set +e
mismatch_out="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import --json list --limit 0 2>/dev/null)"
mismatch_rc=$?
set -e
if [[ "$mismatch_rc" -eq 2 ]] && printf '%s' "$mismatch_out" | python3 -c '
import json, sys
e = json.load(sys.stdin)["error"]
assert e["code"] == "SCHEMA_MISMATCH"
assert e["context"]["found"] == 16 and e["context"]["expected"] == 17
'; then
  ok "0.5.2 list on schema-16 exits 2 with SCHEMA_MISMATCH stdout"
else
  fail "0.5.2 list on schema-16 exits 2 with SCHEMA_MISMATCH stdout (rc=$mismatch_rc out=$mismatch_out)"
fi

cat > "$TMP/br-mismatch-stub.sh" <<EOF
#!/bin/sh
exec cat <<'JSON'
{"error":{"code":"SCHEMA_MISMATCH","message":"expected 17, found 16","context":{"expected":17,"found":16}}}
JSON
EOF
chmod +x "$TMP/br-mismatch-stub.sh"

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME/state"
export MUXA_WHO_CMD="printf '[]\n'"
export MUXA_BROKER_CMD="printf '{\"ok\":false}\n'"
export BR_LIST_CMD="$TMP/br-mismatch-stub.sh"
export CP_JOBS_FILE="$CP_HOME/state/jobs.tsv"
printf '#job\tworker\tworktree\tbranch\n' > "$CP_JOBS_FILE"

set +e
status_err="$("$CP" status --json 2>&1 >/dev/null)"
status_rc=$?
set -e
if [[ "$status_rc" -ne 0 ]] && printf '%s\n' "$status_err" | grep -F -q 'SCHEMA_MISMATCH'; then
  ok "bin/cp status fail-closed on SCHEMA_MISMATCH stub (not missing issues)"
else
  fail "bin/cp status fail-closed on SCHEMA_MISMATCH stub (rc=$status_rc err=$status_err)"
fi

# migrate-schema plan + apply
plan_json="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import doctor migrate-schema plan --json)"
TOKEN="$(printf '%s' "$plan_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["plan_token"])')"
"$BR052" --db "$DB" --no-auto-flush --no-auto-import doctor migrate-schema apply --plan-token "$TOKEN" --json >/dev/null

post_list="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import list --all --json --limit 0)"
if printf '%s' "$post_list" | PRE="$PRE_TOTAL" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
assert d["total"] == int(os.environ["PRE"]), (d["total"], os.environ["PRE"])
issues = d["issues"]
assert any(any(l.startswith("project:") for l in (i.get("labels") or [])) for i in issues)
assert any(any(l.startswith("kind:") for l in (i.get("labels") or [])) for i in issues)
assert any(any(l.startswith("delivery:") for l in (i.get("labels") or [])) for i in issues)
'; then
  ok "post-migrate list --limit 0 preserves total and label axes"
else
  fail "post-migrate list --limit 0 preserves total and label axes"
fi

comments="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import comments list "$OPEN_ID" --json)"
if printf '%s' "$comments" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert any(str(c.get("text", "")).startswith("artifact:v1") for c in rows)
'; then
  ok "post-migrate artifact comment preserved"
else
  fail "post-migrate artifact comment preserved"
fi

limit50="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import list --all --json --limit 50)"
if printf '%s' "$limit50" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["issues"]) == 50
assert d["has_more"] is True
assert d["total"] >= 51
'; then
  ok "post-migrate --limit 50 returns 50 issues and has_more"
else
  fail "post-migrate --limit 50 returns 50 issues and has_more"
fi

limit0="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import list --all --json --limit 0)"
if printf '%s' "$limit0" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert len(d["issues"]) == d["total"]
'; then
  ok "post-migrate --limit 0 returns full issue set"
else
  fail "post-migrate --limit 0 returns full issue set"
fi

changelog="$("$BR052" --db "$DB" --no-auto-flush --no-auto-import changelog --since 2000-01-01 --json)"
if printf '%s' "$changelog" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert any(i.get("id") for g in d.get("groups", []) for i in g.get("issues", []))
'; then
  ok "changelog --since --json has issue ids in groups"
else
  fail "changelog --since --json has issue ids in groups"
fi

if "$BR052" changelog --help 2>&1 | grep -q -- ' -l '; then
  fail "changelog --help still documents -l"
else
  ok "changelog --help has no -l flag"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
