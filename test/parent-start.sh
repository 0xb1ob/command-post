#!/usr/bin/env bash
# Unit tests for scripts/cp-parent-start.sh and the example launchd item. The
# script must start a parent in a pane it was given and must never make one:
# AGENTS.md says command-post may never call tmux directly, so pane creation
# belongs to the operator's login item. Run from the repo: test/parent-start.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT/scripts/cp-parent-start.sh"
PLIST="$ROOT/share/launchd/com.command-post.parent.plist.example"
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-parent-start.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# TMPDIR can end in a slash; the script cds, so compare resolved paths.
TMP="$(cd "$TMP" && pwd -P)"

HOME_OK="$TMP/home"
mkdir -p "$HOME_OK/.beads" "$TMP/bin" "$TMP/home-no-beads"

# muxa stub: prints nothing for `muxa parent` (a root) unless told otherwise.
cat > "$TMP/bin/muxa" <<EOF
#!/bin/sh
if [ "\$1" = "parent" ]; then
  cat "$TMP/parent-name" 2>/dev/null || true
fi
exit 0
EOF
: > "$TMP/parent-name"
# stub agent CLI: records that it was exec'd, in the cwd it was given
cat > "$TMP/bin/fake-agent" <<EOF
#!/bin/sh
printf 'agent started cwd=%s home=%s args=%s\n' "\$PWD" "\$CP_HOME" "\$*" > "$TMP/agent.out"
EOF
chmod +x "$TMP/bin/muxa" "$TMP/bin/fake-agent"

if [[ -x "$START" ]]; then
  ok "scripts/cp-parent-start.sh is executable"
else
  fail "scripts/cp-parent-start.sh is executable"
fi

bash -n "$START" && ok "start script parses" || fail "start script parses"

# --- boundary: no tmux pane commands anywhere in the script ---------------
if grep -nE 'tmux[[:space:]]+(new-session|kill-pane|send-keys|list-panes|capture-pane|display-message|new-window|split-window)' "$START" \
  | grep -vE '^[0-9]+:[[:space:]]*#' | grep -v 'printf' >/dev/null; then
  fail "start script invokes no tmux pane command (AGENTS.md boundary)"
else
  ok "start script invokes no tmux pane command (AGENTS.md boundary)"
fi

# --- refusals --------------------------------------------------------------
expect_rc_msg 2 "not inside a tmux pane" "refuses to run outside a pane instead of making one" \
  env -u TMUX PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$HOME_OK" bash "$START"

expect_rc_msg 2 "tmux new-session -d" "the outside-a-pane refusal names the login-item command" \
  env -u TMUX PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$HOME_OK" bash "$START"

printf 'crisp-lark\n' > "$TMP/parent-name"
expect_rc_msg 2 "muxa child" "refuses to start a parent in a child pane" \
  env TMUX=fake PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$HOME_OK" bash "$START"
: > "$TMP/parent-name"

expect_rc_msg 2 "no .beads" "refuses a home that was never installed" \
  env TMUX=fake PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$TMP/home-no-beads" bash "$START"

expect_rc_msg 2 "not on PATH" "refuses when the agent CLI is absent" \
  env TMUX=fake PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$HOME_OK" CP_PARENT_CMD=no-such-agent bash "$START"

# --- happy path ------------------------------------------------------------
rm -f "$TMP/agent.out"
if env TMUX=fake PATH="$TMP/bin:/usr/bin:/bin" CP_HOME="$HOME_OK" \
  CP_PARENT_CMD="fake-agent --flag" bash "$START" >/dev/null 2>&1; then
  if grep -F -q "cwd=$HOME_OK" "$TMP/agent.out" && grep -F -q -- "args=--flag" "$TMP/agent.out"; then
    ok "starts the agent CLI in the home with CP_PARENT_CMD argv"
  else
    fail "starts the agent CLI in the home with CP_PARENT_CMD argv (got: $(cat "$TMP/agent.out" 2>/dev/null))"
  fi
else
  fail "starts the agent CLI in the home with CP_PARENT_CMD argv (nonzero exit)"
fi

# doctor gaps are advisory: a parent that will not start is worse than a gap.
if grep -F -q 'doctor >/dev/null 2>&1 ||' "$START"; then
  ok "bin/cmdp doctor is advisory, not a gate, on parent start"
else
  fail "bin/cmdp doctor is advisory, not a gate, on parent start"
fi

# --- example launchd item --------------------------------------------------
if python3 - "$PLIST" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], "rb"))
assert d["Label"] == "com.command-post.parent", d
args = d["ProgramArguments"]
assert args[1] == "new-session" and "-d" in args, args
assert any(a.endswith("scripts/cp-parent-start.sh") for a in args), args
assert "KeepAlive" not in d, "no respawn loop: a restarted parent loses its context"
assert d["RunAtLoad"] is True, d
PY
then
  ok "example plist parses, makes the pane, and has no KeepAlive"
else
  fail "example plist parses, makes the pane, and has no KeepAlive"
fi

if grep -F -q "never runs launchctl load on your machine" "$PLIST"; then
  ok "example plist says this repo never loads it"
else
  fail "example plist says this repo never loads it"
fi

printf '\n%d test(s); %d failed\n' "$n" "$failed"
[[ "$failed" -eq 0 ]]
