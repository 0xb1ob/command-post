#!/usr/bin/env bash
# Unit tests for bin/cmdp lease. treehouse is a PATH shim; git runs against
# temp clones. Never touches the live pool. Run: test/lease.sh
set -euo pipefail

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-lease.XXXXXX")"
ORIG_PATH="$PATH"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
export CP_TEST_LEASE="$TMP/leased-a"
export CP_TEST_TH_LOG="$TMP/treehouse.log"
mkdir -p "$CP_HOME" "$TMP/shim"
: > "$CP_TEST_TH_LOG"

make_clone() {
  local dest="$1" branch="${2:-main}"
  mkdir -p "$dest"
  git -C "$dest" init -q -b "$branch"
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
}

CLONE_A="$CP_HOME/projects/demo"
CLONE_B="$CP_HOME/projects/other"
make_clone "$CLONE_A"
make_clone "$CLONE_B"
CLONE_A="$(cd "$CLONE_A" && pwd -P)"
CLONE_B="$(cd "$CLONE_B" && pwd -P)"
git -C "$CLONE_A" worktree add --detach -q "$TMP/leased-a" >/dev/null
LEASE_A="$(cd "$TMP/leased-a" && pwd -P)"
export CP_TEST_LEASE="$LEASE_A"
git -C "$CLONE_B" worktree add --detach -q "$TMP/leased-b" >/dev/null
LEASE_B="$(cd "$TMP/leased-b" && pwd -P)"

cat > "$TMP/shim/treehouse" <<'EOF'
#!/bin/sh
set -eu
printf 'cwd=%s args=%s\n' "$(pwd)" "$*" >> "${CP_TEST_TH_LOG:?}"
case "$1" in
  get)
    if [[ "$(basename "$(pwd)")" == other ]]; then
      printf '%s\n' "${CP_TEST_LEASE_B:?}"
    else
      printf '%s\n' "${CP_TEST_LEASE:?}"
    fi
    ;;
  *)
    printf 'treehouse shim: unexpected %s\n' "$1" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$TMP/shim/treehouse"
export CP_TEST_LEASE_B="$LEASE_B"
export PATH="$TMP/shim:$ORIG_PATH"

# lease keys off canonical clone, not process cwd
: > "$CP_TEST_TH_LOG"
out="$(cd "$CLONE_B" && "$CP" lease --project demo 2>/dev/null)" || rc=$?
rc=${rc:-0}
if [[ "$rc" -ne 0 ]]; then
  fail "lease from wrong cwd succeeds (rc=$rc)"
elif [[ "$out" == "$LEASE_A" ]]; then
  ok "lease from wrong cwd still leases demo clone"
else
  fail "lease stdout (got $out want $LEASE_A)"
fi
if grep -F "cwd=$CLONE_A args=get --lease" "$CP_TEST_TH_LOG" >/dev/null; then
  ok "treehouse get runs with cwd in projects/demo"
else
  fail "treehouse cwd should be demo clone (log=$(cat "$CP_TEST_TH_LOG"))"
fi

# stdout is path only
: > "$CP_TEST_TH_LOG"
if [[ "$("$CP" lease --project demo 2>/dev/null)" == "$LEASE_A" ]]; then
  ok "lease prints absolute worktree path on stdout"
else
  fail "lease stdout path"
fi

# missing project
expect_rc_msg 1 "project clone not at" "missing projects/<name> is refused" \
  env CP_HOME="$TMP/empty" "$CP" lease --project missing

# usage
expect_rc_msg 2 "missing --project NAME" "lease requires --project" \
  "$CP" lease

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
