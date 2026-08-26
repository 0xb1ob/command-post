#!/usr/bin/env bash
# Unit tests for bin/cp models catalog, allowlist, and rubric.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CP="$ROOT/bin/cp"
FIXTURE="$ROOT/test/fixtures/models/agent-models.txt"
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-models.XXXXXX")"
ORIG_PATH="$PATH"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME" "$TMP/shim" "$TMP/host"

make_shim() {
  local name="$1"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/shim/$name"
  chmod +x "$TMP/shim/$name"
}

make_agent_models_shim() {
  cat > "$TMP/shim/agent" <<EOF
#!/bin/sh
if [ "\${1:-}" = "models" ]; then
  cat "$FIXTURE"
  exit 0
fi
exit 0
EOF
  chmod +x "$TMP/shim/agent"
}

ensure_host_utils() {
  mkdir -p "$TMP/host"
  local c p
  for c in rm mkdir mktemp bash awk sed grep chmod printf python3 date cat head tr wc; do
    p="$(PATH="$ORIG_PATH" command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "$TMP/host/$c" ]] && ln -sf "$p" "$TMP/host/$c"
  done
}

host_path() {
  printf '%s' "$ORIG_PATH" | tr ':' '\n' | while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$d" in
      "$TMP/shim"|"$TMP/host") continue ;;
    esac
    [[ -x "$d/agent" || -x "$d/claude" || -x "$d/cursor-agent" ]] && continue
    printf '%s:' "$d"
  done | sed 's/:$//'
}

set_test_path() {
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(host_path)"
}

plant_catalog() {
  local argv0="$1" listing="$2" epoch="${3:-}"
  mkdir -p "$CP_HOME/data/models"
  if [[ -z "$epoch" ]]; then
    epoch="$(date -u +%s)"
  fi
  python3 - "$ROOT/share/families.tsv" "$listing" "$CP_HOME/data/models/${argv0}.tsv" <<'PY'
import re, sys
fam_path, listing, outp = sys.argv[1:4]
rules = []
with open(fam_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) >= 2:
            rules.append((parts[0], parts[1]))

def family_of(slug):
    for fam, regex in rules:
        if re.search(regex, slug):
            return fam
    return "other"

header = False
pat = re.compile(r"^([a-z0-9][a-z0-9.-]*) - (.+)$")
rows = []
with open(listing) as f:
    for line in f:
        line = line.rstrip("\n")
        if line == "Available models":
            header = True
            continue
        if not header:
            continue
        m = pat.match(line)
        if not m:
            continue
        slug, display = m.group(1), m.group(2)
        if slug == "auto":
            continue
        rows.append((slug, family_of(slug), display))
with open(outp, "w") as o:
    o.write("# slug\tfamily\tdisplay\n")
    for slug, fam, display in rows:
        o.write("%s\t%s\t%s\n" % (slug, fam, display))
PY
  cat > "$CP_HOME/data/models/${argv0}.meta" <<EOF
fetched_at=2026-08-26T19:01:00Z
fetched_epoch=${epoch}
cli_path=$TMP/shim/${argv0}
cli_version=test
status=ok
static=false
EOF
}

make_agent_models_shim
make_shim claude
set_test_path

# Parse fixture: drop auto, classify families, keep (NO ZDR) / kimi / claude-4.6-opus-high
"$CP" models refresh --cli agent --quiet
tsv="$CP_HOME/data/models/agent.tsv"
if [[ -f "$tsv" ]] && ! grep -F -q $'\tauto\t' "$tsv" && ! grep -F -q $'auto\t' "$tsv"; then
  ok "refresh drops auto"
else
  fail "refresh drops auto (tsv=$(cat "$tsv" 2>/dev/null))"
fi
if grep -F -q 'claude-fable-5-high' "$tsv" && grep -F -q '(NO ZDR)' "$tsv"; then
  ok "refresh keeps (NO ZDR) display"
else
  fail "refresh keeps (NO ZDR)"
fi
if grep -F -q $'kimi-k3-low\tother\t' "$tsv"; then
  ok "kimi-* classifies as other"
else
  fail "kimi-* classifies as other ($(grep kimi "$tsv" || true))"
fi
if grep -F -q $'claude-4.6-opus-high\tanthropic\t' "$tsv"; then
  ok "claude-4.6-opus-high classifies as anthropic"
else
  fail "claude-4.6-opus-high family"
fi

cursor_n="$(awk -F'\t' '$2=="cursor"{c++} END{print c+0}' "$tsv")"
grok_n="$(awk -F'\t' '$2=="grok"{c++} END{print c+0}' "$tsv")"
anth_n="$(awk -F'\t' '$2=="anthropic"{c++} END{print c+0}' "$tsv")"
if [[ "$cursor_n" -eq 2 ]]; then
  ok "fixture family cursor=2"
else
  fail "fixture family cursor=2 (got $cursor_n)"
fi
if [[ "$grok_n" -ge 10 ]]; then
  ok "fixture family grok>=10"
else
  fail "fixture family grok>=10 (got $grok_n)"
fi
if [[ "$anth_n" -ge 8 ]]; then
  ok "fixture family anthropic>=8"
else
  fail "fixture family anthropic (got $anth_n)"
fi

# Generated listing: family counts including openai/gemini/other
gen="$TMP/gen-models.txt"
{
  printf 'Available models\n\n'
  printf 'auto - Auto (default)\n'
  printf 'composer-2.5 - Composer 2.5\n'
  printf 'composer-2.5-fast - Composer 2.5 Fast\n'
  i=0
  while [[ "$i" -lt 10 ]]; do
    printf 'cursor-grok-4.6-high-%s - Grok %s\n' "$i" "$i"
    i=$((i + 1))
  done
  i=0
  while [[ "$i" -lt 50 ]]; do
    printf 'claude-sonnet-5-%s - Claude %s\n' "$i" "$i"
    i=$((i + 1))
  done
  i=0
  while [[ "$i" -lt 50 ]]; do
    printf 'gpt-5.5-%s - GPT %s\n' "$i" "$i"
    i=$((i + 1))
  done
  i=0
  while [[ "$i" -lt 5 ]]; do
    printf 'gemini-2.5-%s - Gemini %s\n' "$i" "$i"
    i=$((i + 1))
  done
  printf 'kimi-k3-low - Kimi\n'
} > "$gen"
cat > "$TMP/shim/agent" <<EOF
#!/bin/sh
if [ "\${1:-}" = "models" ]; then
  cat "$gen"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/shim/agent"
rm -f "$CP_HOME/data/models/agent.tsv" "$CP_HOME/data/models/agent.meta"
"$CP" models refresh --cli agent --quiet
tsv="$CP_HOME/data/models/agent.tsv"
gc="$(awk -F'\t' '$2=="cursor"{c++} END{print c+0}' "$tsv")"
gg="$(awk -F'\t' '$2=="grok"{c++} END{print c+0}' "$tsv")"
ga="$(awk -F'\t' '$2=="anthropic"{c++} END{print c+0}' "$tsv")"
go="$(awk -F'\t' '$2=="openai"{c++} END{print c+0}' "$tsv")"
ge="$(awk -F'\t' '$2=="gemini"{c++} END{print c+0}' "$tsv")"
go2="$(awk -F'\t' '$2=="other"{c++} END{print c+0}' "$tsv")"
if [[ "$gc" -eq 2 && "$gg" -ge 10 && "$ga" -ge 50 && "$go" -ge 50 && "$ge" -ge 5 && "$go2" -ge 1 ]]; then
  ok "generated listing family counts"
else
  fail "generated listing family counts (cursor=$gc grok=$gg anth=$ga openai=$go gemini=$ge other=$go2)"
fi
if grep -F -q $'auto\t' "$tsv"; then
  fail "generated listing dropped auto"
else
  ok "generated listing dropped auto"
fi

# Garbage listing → status=failed, previous catalog retained
printf 'not a listing\n' > "$TMP/bad-models.txt"
cat > "$TMP/shim/agent" <<EOF
#!/bin/sh
if [ "\${1:-}" = "models" ]; then
  cat "$TMP/bad-models.txt"
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/shim/agent"
cp "$tsv" "$TMP/prev.tsv"
"$CP" models refresh --cli agent --quiet 2>"$TMP/err.fail" || true
if grep -F -q 'status=failed' "$CP_HOME/data/models/agent.meta" \
  && python3 -c 'import sys; sys.exit(open(sys.argv[1]).read()!=open(sys.argv[2]).read())' \
    "$CP_HOME/data/models/agent.tsv" "$TMP/prev.tsv"; then
  ok "garbage listing keeps previous catalog and marks failed"
else
  fail "garbage listing retain (meta=$(cat "$CP_HOME/data/models/agent.meta"))"
fi

# Restore a working catalog from the fixture for allow/check tests
make_agent_models_shim
rm -f "$CP_HOME/data/models/agent.meta"
"$CP" models refresh --cli agent --quiet

expect_rc_msg 2 "family openai not in allow" "default allow refuses gpt" \
  "$CP" models check gpt-5.5-high --cli agent
expect_rc_msg 0 "" "CP_MODELS_ALLOW adds openai" \
  env CP_MODELS_ALLOW="cursor,grok,anthropic,openai" "$CP" models check gpt-5.5-high --cli agent
expect_rc_msg 2 "empty allowlist" "empty allowlist fails closed" \
  env CP_MODELS_ALLOW="" "$CP" models check composer-2.5-fast --cli agent
expect_rc_msg 2 "claude kind accepts anthropic only" "claude rejects non-anthropic slug" \
  "$CP" models check gpt-5.5-high --cli claude
expect_rc_msg 0 "" "claude accepts fable" \
  "$CP" models check fable --cli claude
expect_rc_msg 0 "" "claude accepts claude-fable-5" \
  "$CP" models check claude-fable-5 --cli claude
expect_rc_msg 2 "not in" "unknown cursor slug fail-closed when catalog exists" \
  "$CP" models check composer-9.9 --cli agent
expect_rc_msg 0 "" "CP_MODELS_VALIDATE=off skips catalog membership" \
  env CP_MODELS_VALIDATE=off "$CP" models check composer-9.9 --cli agent

# haiku is not in claude --help aliases — refuse
expect_rc_msg 2 "claude kind accepts anthropic only" "haiku is not a verified Claude alias" \
  "$CP" models check haiku --cli claude

# TTL: backdated meta is stale
old=$(( $(date -u +%s) - 100 ))
plant_catalog agent "$FIXTURE" "$old"
stale_out="$(CP_MODELS_TTL_SEC=1 "$CP" models --cli agent 2>/dev/null)" || true
if printf '%s\n' "$stale_out" | grep -F -q '(stale)'; then
  ok "TTL marks catalog stale"
else
  fail "TTL stale (out=$stale_out)"
fi
now="$(date -u +%s)"
plant_catalog agent "$FIXTURE" "$now"
fresh_out="$("$CP" models --cli agent 2>/dev/null)" || true
if printf '%s\n' "$fresh_out" | grep -F -q '(fresh)'; then
  ok "fresh catalog status"
else
  fail "fresh catalog (out=$fresh_out)"
fi

# --json includes count/status
json="$("$CP" models --json 2>/dev/null)" || true
if printf '%s\n' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "agent" in d
assert d["agent"]["count"] >= 2
assert d["agent"]["status"] in ("fresh", "stale", "failed", "none", "static")
assert "stale" in d["agent"]
'; then
  ok "models --json shape"
else
  fail "models --json shape (out=$json)"
fi

# Rubric via JOB_SCOPE/JOB_RISK (no routing.tsv)
rm -f "$CP_HOME/data/routing.tsv"
# doctor host shims
cat > "$TMP/shim/muxa" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
  printf '1.0.16 (test)\n'
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/shim/muxa"
cat > "$TMP/shim/br" <<'EOF'
#!/bin/sh
if [ "$1" = "--version" ]; then
  printf 'br 0.5.2\n'
  exit 0
fi
if [ "$1" = "create" ] && [ "$2" = "--help" ]; then
  printf '      --slug <SLUG>\n'
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/shim/br"
make_shim treehouse
export MUXA_WHO_CMD="muxa who --json"
set_test_path

rubric_assert() {
  local scope="$1" risk="$2" role="$3" want="$4" label="$5"
  local out
  out="$(JOB_SCOPE="$scope" JOB_RISK="$risk" "$CP" doctor --json 2>/dev/null)" || true
  if printf '%s\n' "$out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
argv = d['roles']['$role']['argv']
assert '--model' in argv, argv
i = argv.index('--model')
assert argv[i+1] == '$want', argv
"
  then
    ok "$label"
  else
    fail "$label (out=$out)"
  fi
}

rubric_assert S low implementer composer-2.5-fast "rule 6 small ship → composer-2.5-fast"
rubric_assert M low implementer cursor-grok-4.6-high "rule 7 medium ship → cursor-grok-4.6-high"
rubric_assert L low implementer cursor-grok-4.6-high "rule 7 large ship → cursor-grok-4.6-high"
rubric_assert S high implementer cursor-grok-4.6-high "rule 5 risky ship → cursor-grok-4.6-high"
rubric_assert S low researcher cursor-grok-4.6-high-fast "rule 4 bounded research → grok high-fast"
rubric_assert L low researcher cursor-grok-4.6-xhigh "rule 3 large research → grok xhigh"
rubric_assert S low gate-reviewer composer-2.5-fast "rule 2 gate → composer-2.5-fast"

# Claude-only rubric (never sonnet for research)
rm -f "$TMP/shim/agent" "$TMP/shim/cursor-agent"
make_shim claude
set_test_path
out="$(JOB_SCOPE=S JOB_RISK=low "$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["roles"]["researcher"]["argv"][-1] == "fable"
assert d["roles"]["researcher"]["model_status"] == "static"
assert d["models"]["claude"]["status"] == "static"
'; then
  ok "claude bounded research → fable (static)"
else
  fail "claude bounded research fable (out=$out)"
fi
out="$(JOB_SCOPE=L JOB_RISK=low "$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["roles"]["researcher"]["argv"][-1] == "claude-fable-5"
'; then
  ok "claude large research → claude-fable-5"
else
  fail "claude large research (out=$out)"
fi

# Tie-breaker: catalog lacks cursor-grok-4.6-high-fast but has cursor-grok-4.6-high
make_agent_models_shim
set_test_path
mkdir -p "$CP_HOME/data/models"
printf '# slug\tfamily\tdisplay\ncomposer-2.5-fast\tcursor\tComposer 2.5 Fast\ncursor-grok-4.6-high\tgrok\tGrok\n' \
  > "$CP_HOME/data/models/agent.tsv"
now="$(date -u +%s)"
cat > "$CP_HOME/data/models/agent.meta" <<EOF
fetched_at=2026-08-26T19:01:00Z
fetched_epoch=${now}
status=ok
static=false
EOF
out="$(JOB_SCOPE=S JOB_RISK=low "$CP" doctor --json 2>"$TMP/err.sub")" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
argv = d["roles"]["researcher"]["argv"]
assert argv[argv.index("--model")+1] == "cursor-grok-4.6-high"
' && grep -F -q 'substituted cursor-grok-4.6-high-fast → cursor-grok-4.6-high' "$TMP/err.sub"; then
  ok "tie-break same-base substitutes grok high-fast → high"
else
  fail "tie-break same-base (out=$out err=$(cat "$TMP/err.sub"))"
fi

# Catalog lacks cursor family entirely → next prefer (grok)
printf '# slug\tfamily\tdisplay\ncursor-grok-4.6-high\tgrok\tGrok\n' \
  > "$CP_HOME/data/models/agent.tsv"
out="$(JOB_SCOPE=S JOB_RISK=low "$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
argv = d["roles"]["implementer"]["argv"]
assert argv[argv.index("--model")+1] == "cursor-grok-4.6-high"
'; then
  ok "tie-break next family is grok"
else
  fail "tie-break next family (out=$out)"
fi

# Nothing to substitute → exit 2 from models check / apply
printf '# slug\tfamily\tdisplay\ngpt-5.5-high\topenai\tGPT\n' \
  > "$CP_HOME/data/models/agent.tsv"
if JOB_SCOPE=S JOB_RISK=low "$CP" doctor --json >/dev/null 2>"$TMP/err.nosub"; then
  # doctor may still exit 0 if apply_rubric dies... apply_rubric exits 2
  fail "empty prefer families should fail rubric apply"
else
  if grep -F -q 'no allowed catalog slug' "$TMP/err.nosub"; then
    ok "nothing to substitute fails closed"
  else
    fail "nothing to substitute (err=$(cat "$TMP/err.nosub"))"
  fi
fi

# Allow-filtered listing hides openai; --all shows it
make_agent_models_shim
rm -f "$CP_HOME/data/models/agent.meta"
"$CP" models refresh --cli agent --quiet
lst="$("$CP" models --cli agent 2>/dev/null)" || true
if printf '%s\n' "$lst" | grep -F -q 'gpt-5.5-high'; then
  fail "default listing hides openai"
else
  ok "default listing hides openai"
fi
all="$("$CP" models --cli agent --all 2>/dev/null)" || true
if printf '%s\n' "$all" | grep -F -q 'gpt-5.5-high'; then
  ok "--all shows openai"
else
  fail "--all shows openai"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
