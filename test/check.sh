#!/usr/bin/env bash
# Unit tests for bin/cp check git/clone preflight (not a live dispatch E2E).
# Occupancy is stubbed via MUXA_WHO_CMD. Run: test/check.sh
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cp-check.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

export CP_HOME="$TMP/home"
mkdir -p "$CP_HOME"

printf '[]\n' > "$TMP/who.json"
export MUXA_WHO_CMD="cat $TMP/who.json"

make_clone() {
  local dest="$1" branch="${2:-main}"
  mkdir -p "$dest"
  git -C "$dest" init -q -b "$branch"
  git -C "$dest" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
}

CLONE="$CP_HOME/projects/demo"
make_clone "$CLONE"
CLONE="$(cd "$CLONE" && pwd -P)"
git -C "$CLONE" worktree add -q "$TMP/wt" >/dev/null
WT="$(cd "$TMP/wt" && pwd -P)"

# happy path: canonical clone, linked worktree, primary on default branch
expect_rc_msg 0 "clone $CLONE" "canonical clone is projects/<name>" \
  "$CP" check --project demo "$WT"
expect_rc_msg 0 "worktree $WT linked" "target is a linked worktree of that clone" \
  "$CP" check --project demo "$WT"
expect_rc_msg 0 "primary $CLONE on main" "primary checkout is on the default branch" \
  "$CP" check --project demo "$WT"

# relative WORKTREE resolves against the clone, not process cwd
git -C "$CLONE" worktree add -q "$CLONE/rel-wt" >/dev/null
REL_WT="$(cd "$CLONE/rel-wt" && pwd -P)"
expect_rc_msg 0 "worktree $REL_WT linked" "relative worktree path resolves against the clone" \
  "$CP" check --project demo rel-wt

# missing clone
mkdir -p "$TMP/empty/projects"
expect_rc_msg 1 "project clone not at $TMP/empty/projects/missing" "missing projects/<name> is refused" \
  env CP_HOME="$TMP/empty" MUXA_WHO_CMD="$MUXA_WHO_CMD" "$CP" check --project missing "$WT"

# invalid project name
expect_rc_msg 1 "invalid project name" "invalid project name is refused" \
  "$CP" check --project 'bad name' "$WT"

# nested wrong git: projects/demo lives inside another repo and is not its own clone
NEST="$TMP/nested"
mkdir -p "$NEST/projects/demo"
git -C "$NEST" init -q -b main
git -C "$NEST" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init
expect_rc_msg 1 "nested wrong git" "nested directory of another git is refused" \
  env CP_HOME="$NEST" MUXA_WHO_CMD="$MUXA_WHO_CMD" "$CP" check --project demo "$WT"

# projects/<name> is a linked worktree, not a primary clone
OTHER_PRIMARY="$TMP/other-primary"
make_clone "$OTHER_PRIMARY"
NOT_PRIMARY="$TMP/home2/projects/demo"
mkdir -p "$TMP/home2/projects"
git -C "$OTHER_PRIMARY" worktree add -q "$NOT_PRIMARY" >/dev/null
expect_rc_msg 1 "is not a primary clone" "worktree masquerading as projects/<name> is refused" \
  env CP_HOME="$TMP/home2" MUXA_WHO_CMD="$MUXA_WHO_CMD" "$CP" check --project demo "$WT"

# belongs to another repo
OTHER="$TMP/other"
make_clone "$OTHER"
git -C "$OTHER" worktree add -q "$TMP/other-wt" >/dev/null
OTHER_WT="$(cd "$TMP/other-wt" && pwd -P)"
expect_rc_msg 1 "belongs to another repo" "foreign worktree prints belongs-to-another-repo" \
  "$CP" check --project demo "$OTHER_WT"

# primary checkout is not a linked worktree
expect_rc_msg 1 "is the primary checkout, not a linked worktree" "primary checkout is refused as a dispatch worktree" \
  "$CP" check --project demo "$CLONE"

# missing worktree path
expect_rc_msg 1 "does not exist" "missing worktree path is refused" \
  "$CP" check --project demo "$TMP/no-such-wt"

# primary on the wrong branch
git -C "$CLONE" checkout -q -b other
expect_rc_msg 1 "on other (want main)" "primary off the default branch is refused" \
  "$CP" check --project demo "$WT"

# --base overrides the expected primary branch
expect_rc_msg 0 "primary $CLONE on other" "--base accepts the primary's current branch" \
  "$CP" check --project demo --base other "$WT"
expect_rc_msg 1 "on other (want main)" "--base main still fails while primary is on other" \
  "$CP" check --project demo --base main "$WT"

# primary detached
git -C "$CLONE" checkout -q --detach
expect_rc_msg 1 "is detached (want other)" "detached primary is refused" \
  "$CP" check --project demo --base other "$WT"

# restore primary onto a branch so later cases are not confused
git -C "$CLONE" checkout -q other

# ~/name must not be the lease source (symlink projects/<name> → ~/name)
HOME_CASE="$TMP/homecase"
mkdir -p "$HOME_CASE/real" "$HOME_CASE/projects"
make_clone "$HOME_CASE/real/demo"
ln -s "$HOME_CASE/real/demo" "$HOME_CASE/projects/demo"
ln -s "$HOME_CASE/real/demo" "$HOME_CASE/demo"
git -C "$HOME_CASE/real/demo" worktree add -q "$TMP/home-wt" >/dev/null
HOME_WT="$(cd "$TMP/home-wt" && pwd -P)"
expect_rc_msg 1 "resolves to ~/" "projects/<name> that resolves to ~/name is refused" \
  env HOME="$HOME_CASE" CP_HOME="$HOME_CASE" MUXA_WHO_CMD="$MUXA_WHO_CMD" \
  "$CP" check --project demo "$HOME_WT"

if [[ "$failed" -ne 0 ]]; then
  printf '%d failed of %d\n' "$failed" "$n" >&2
  exit 1
fi
printf '%d passed\n' "$n"
