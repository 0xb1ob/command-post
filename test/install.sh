#!/usr/bin/env bash
# install.sh contract checks (muxa broker + project hooks).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="$ROOT/bin/install.sh"
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

has() {
  local file="$1" needle="$2" label="$3"
  if grep -F -q -- "$needle" "$file"; then
    ok "$label"
  else
    fail "$label (missing $(printf %q "$needle") in $file)"
  fi
}

lacks() {
  local file="$1" needle="$2" label="$3"
  if grep -F -q -- "$needle" "$file"; then
    fail "$label (still has $(printf %q "$needle") in $file)"
  else
    ok "$label"
  fi
}

lacks "$INSTALL" 'check_muxa_broker' "install.sh no longer calls check_muxa_broker"
lacks "$INSTALL" 'broker="$bin_dir/muxa-broker"' "install.sh does not look for muxa-broker next to muxa"
has "$INSTALL" 'verify_muxa' "install.sh verifies muxa after install"
has "$INSTALL" 'ensure_muxa_hooks' "install.sh checks project hook config"
has "$INSTALL" 'muxa broker start' "install.sh documents broker via muxa broker"

[[ -x "$ROOT/scripts/muxa-hook.sh" ]] && ok "scripts/muxa-hook.sh is executable" \
  || fail "scripts/muxa-hook.sh is executable"
[[ -f "$ROOT/.claude/settings.json" ]] && ok ".claude/settings.json exists" \
  || fail ".claude/settings.json exists"
[[ -f "$ROOT/.cursor/hooks.json" ]] && ok ".cursor/hooks.json exists" \
  || fail ".cursor/hooks.json exists"
grep -F -q 'scripts/muxa-hook.sh session-start --kind claude' "$ROOT/.claude/settings.json" \
  && ok "Claude hook points at scripts/muxa-hook.sh" \
  || fail "Claude hook points at scripts/muxa-hook.sh"
grep -F -q 'scripts/muxa-hook.sh session-start --kind cursor' "$ROOT/.cursor/hooks.json" \
  && ok "Cursor hook points at scripts/muxa-hook.sh" \
  || fail "Cursor hook points at scripts/muxa-hook.sh"
grep -F -q 'command -v muxa' "$ROOT/scripts/muxa-hook.sh" \
  && ok "hook script resolves muxa from PATH" \
  || fail "hook script resolves muxa from PATH"
grep -F -q '$ROOT/bin/muxa' "$ROOT/scripts/muxa-hook.sh" \
  && fail "hook script does not assume command-post ships bin/muxa" \
  || ok "hook script does not assume command-post ships bin/muxa"

has "$INSTALL" 'python3' "install.sh require_prereqs includes python3"
has "$INSTALL" 'bin/cp' "install.sh mentions python3 is for bin/cp"
has "$INSTALL" 'BR_VERSION_PIN="v0.5.2"' \
  "install.sh declares beads_rust pin"
has "$INSTALL" '--version "$BR_VERSION_PIN"' \
  "install.sh curl passes pinned version via BR_VERSION_PIN"
has "$INSTALL" 'list --json' \
  "install.sh gates on br list --json against the home db, not --slug"
has "$INSTALL" 'migrate-schema' \
  "install.sh names doctor migrate-schema when list --json fails"
lacks "$INSTALL" 'br_create_supports_slug' \
  "install.sh does not skip or upgrade based on the --slug probe"
lacks "$INSTALL" 'lacks --slug' \
  "install.sh log/probe no longer treats missing --slug as the upgrade reason"

if [[ "$failed" -eq 0 ]]; then
  printf '\n# %d tests passed\n' "$n"
  exit 0
fi
printf '\n# %d passed, %d failed\n' "$((n - failed))" "$failed"
exit 1
