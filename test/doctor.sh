#!/usr/bin/env bash
# Unit tests for bin/cp doctor. PATH-isolated worker CLI shims.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-doctor.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME" "$TMP/shim" "$TMP/host"

make_shim() {
  local name="$1"
  printf '#!/bin/sh\nexit 0\n' > "$TMP/shim/$name"
  chmod +x "$TMP/shim/$name"
}

ensure_host_utils() {
  mkdir -p "$TMP/host"
  local c p
  for c in rm mkdir mktemp bash awk sed grep chmod printf python3; do
    p="$(command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" ]] && ln -sf "$p" "$TMP/host/$c"
  done
}

# Host tools from real PATH except worker CLIs (empty shim dir only has our shims).
host_path() {
  printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    case "$d" in
      "$TMP/shim"|"$TMP/host") continue ;;
    esac
    [[ -x "$d/agent" || -x "$d/claude" || -x "$d/cursor-agent" ]] && continue
    printf '%s:' "$d"
  done | sed 's/:$//'
}

setup_path_no_workers() {
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(host_path)"
}

setup_path_with() {
  local name="$1"
  make_shim "$name"
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(host_path)"
}

# muxa/br/treehouse shims for doctor host section when real ones absent from trimmed path
make_shim muxa
make_shim br
make_shim treehouse
export MUXA_WHO_CMD="muxa who --json"
setup_path_no_workers

# Host python3 present → exit 0, JSON ok
out="$("$CP" doctor --json 2>"$TMP/err.doc")" || rc=$?
rc=${rc:-0}
if [[ "$rc" -eq 0 ]]; then
  ok "doctor exit 0 when host tools present"
else
  fail "doctor exit 0 when host tools present (rc=$rc err=$(cat "$TMP/err.doc"))"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["host"]["python3"]["ok"] is True
assert d["host"]["python3"]["path"]
'; then
  ok "doctor JSON has python3.ok=true with path"
else
  fail "doctor JSON python3 (out=$out)"
fi

# Worker matrix: none installed
setup_path_no_workers
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for name in ("agent", "cursor-agent", "claude"):
    assert d["clis"][name]["installed"] is False
'; then
  ok "no worker shims → all clis installed=false"
else
  fail "no worker shims matrix"
fi

# claude shim only
setup_path_with claude
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["clis"]["claude"]["installed"] is True
assert d["clis"]["agent"]["installed"] is False
assert d["clis"]["cursor-agent"]["installed"] is False
'; then
  ok "claude shim only → claude true, others false"
else
  fail "claude-only shim matrix"
fi

# routing.tsv researcher → claude
mkdir -p "$CP_HOME/data"
cat > "$CP_HOME/data/routing.tsv" <<'EOF'
researcher	claude	--model	opus
implementer	agent	--model	composer-2.5-fast
gate-reviewer	agent	--model	composer-2.5-fast
EOF
setup_path_with claude
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["roles"]["researcher"]
assert r["argv0"] == "claude"
assert r["source"] == "routing"
'; then
  ok "routing.tsv researcher → claude with source=routing"
else
  fail "routing.tsv researcher role"
fi

# without routing file → shipped defaults
rm -f "$CP_HOME/data/routing.tsv"
setup_path_with agent
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["roles"]["researcher"]
assert r["argv0"] == "agent"
assert r["source"] == "shipped"
'; then
  ok "without routing.tsv → shipped agent defaults"
else
  fail "shipped defaults in doctor JSON"
fi

# forbid row appears in JSON
cat > "$CP_HOME/data/routing.tsv" <<'EOF'
forbid	claude
EOF
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "claude" in d["forbid"]
'; then
  ok "forbid claude appears in doctor JSON"
else
  fail "forbid in doctor JSON"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
