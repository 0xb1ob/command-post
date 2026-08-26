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
ORIG_PATH="$PATH"
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
    p="$(PATH="$ORIG_PATH" command -v "$c" 2>/dev/null || true)"
    [[ -n "$p" && "$p" != "$TMP/host/$c" ]] && ln -sf "$p" "$TMP/host/$c"
  done
}

# Host tools from real PATH except worker CLIs (empty shim dir only has our shims).
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

setup_path_no_workers() {
  rm -f "$TMP/shim/agent" "$TMP/shim/claude" "$TMP/shim/cursor-agent"
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(host_path)"
}

setup_path_with() {
  local name="$1"
  rm -f "$TMP/shim/agent" "$TMP/shim/claude" "$TMP/shim/cursor-agent"
  make_shim "$name"
  ensure_host_utils
  export PATH="$TMP/shim:$TMP/host:$(host_path)"
}

# muxa/br/treehouse shims for doctor host section when real ones absent from trimmed path
cat > "$TMP/shim/muxa" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
  printf '1.0.17 (test)\n'
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
assert d["host"]["muxa"]["ok"] is True
assert d["host"]["muxa"]["version_ok"] is True
'; then
  ok "doctor JSON has muxa.ok=true with version_ok"
else
  fail "doctor JSON muxa version (out=$out)"
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

# claude shim only → derived routing for all roles
setup_path_with claude
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for role in ("researcher", "implementer", "gate-reviewer"):
    r = d["roles"][role]
    assert r["argv0"] == "claude", role
    assert r["source"] == "derived", role
    assert r["installed"] is True, role
'; then
  ok "claude-only host → all roles derived to claude"
else
  fail "claude-only derived routing"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["models"]["claude"]["status"] == "static"
assert d["roles"]["implementer"]["model_status"] == "static"
assert d["roles"]["researcher"]["argv"][-1] == "fable"
'; then
  ok "claude-only host → static catalog and fable research slug"
else
  fail "claude-only static model_status"
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
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "models" in d
assert "agent" in d["models"]
assert d["models"]["agent"]["status"] in ("none", "failed", "fresh", "stale", "static")
assert d["roles"]["implementer"]["model_status"] in (
    "in-catalog", "not-in-catalog", "unvalidated(no catalog)", "static"
)
'; then
  ok "doctor JSON Models section and role model_status"
else
  fail "doctor JSON models (out=$out)"
fi

# forbid row excludes CLI from derivation
rm -f "$CP_HOME/data/routing.tsv"
cat > "$CP_HOME/data/routing.tsv" <<'EOF'
forbid	claude
EOF
setup_path_no_workers
make_shim cursor-agent
make_shim claude
export PATH="$TMP/shim:$TMP/host:$(host_path)"
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert "claude" in d["forbid"]
r = d["roles"]["implementer"]
assert r["source"] == "derived"
assert r["argv0"] == "cursor-agent"
'; then
  ok "forbid claude excludes it from derivation"
else
  fail "forbid excludes from derivation"
fi

# forbid row appears in JSON (agent installed, claude forbidden)
setup_path_with agent
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

# zero worker CLIs → derived routing reports missing with install hint
rm -f "$CP_HOME/data/routing.tsv"
setup_path_no_workers
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["roles"]["implementer"]
assert r["source"] == "derived"
assert r["installed"] is False
assert any("agent" in m["what"] or "install one of" in m["fix"] for m in d["missing"])
'; then
  ok "no worker shims → derived source with missing install hint"
else
  fail "zero installed derived missing hint"
fi

# agent + claude installed, no routing → shipped (agent default installed)
rm -f "$CP_HOME/data/routing.tsv"
make_shim claude
setup_path_with agent
out="$("$CP" doctor --json 2>/dev/null)" || true
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
r = d["roles"]["researcher"]
assert r["argv0"] == "agent"
assert r["source"] == "shipped"
'; then
  ok "agent installed → shipped defaults unchanged"
else
  fail "agent installed keeps shipped defaults"
fi

# muxa version mismatch → exit 2 and version_ok=false
cat > "$TMP/shim/muxa" <<'EOF'
#!/bin/sh
if [ "$1" = "version" ]; then
  printf '1.0.15 (old)\n'
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/shim/muxa"
setup_path_with agent
out="$("$CP" doctor --json 2>"$TMP/err.muxa")" || rc=$?
rc=${rc:-0}
if [[ "$rc" -eq 2 ]]; then
  ok "doctor exit 2 when muxa version mismatches pin"
else
  fail "doctor exit 2 when muxa version mismatches pin (rc=$rc)"
fi
if printf '%s\n' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["host"]["muxa"]["version_ok"] is False
assert any(m["what"] == "muxa 1.0.17" for m in d["missing"])
'; then
  ok "doctor JSON reports muxa version mismatch"
else
  fail "doctor JSON muxa version mismatch (out=$out)"
fi

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
