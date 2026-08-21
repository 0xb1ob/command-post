#!/usr/bin/env bash
# Idempotent command-post setup. No arguments.
# Phase 1 (deps): muxa (+ the muxa-broker binary its installer ships), br
# (beads), treehouse — skip if already on PATH. Nothing here compiles.
# Phase 2 (scaffold): data/, projects/, data/*.md templates, br init --prefix cp,
# copy tracked skills/ into gitignored agent-harness skill dirs.
# Run once after clone; safe to re-run (muxa refreshes skills/hooks; skill copies refresh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${CP_BIN_DIR:-$HOME/.local/bin}"

MUXA_INSTALL_URL="${MUXA_INSTALL_URL:-https://raw.githubusercontent.com/0xb1ob/muxa/main/install.sh}"
BR_INSTALL_URL="${BR_INSTALL_URL:-https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh}"
TREEHOUSE_INSTALL_URL="${TREEHOUSE_INSTALL_URL:-https://kunchenguid.github.io/treehouse/install.sh}"

log() { printf '[install] %s\n' "$*"; }
warn() { printf '[install] warning: %s\n' "$*" >&2; }
die() { printf '[install] error: %s\n' "$*" >&2; exit 1; }

on_path() {
  case ":${PATH}:" in
    *:"$1":*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_bin_dir() {
  mkdir -p "$BIN"
  if ! on_path "$BIN"; then
    warn "$BIN is not on PATH — add: export PATH=\"\$HOME/.local/bin:\$PATH\""
  fi
}

require_prereqs() {
  local missing=0
  # python3: muxa's installer merges agent hooks with it, and we use it to
  # resolve the realpath of bin/muxa when locating muxa-broker.
  for cmd in git curl tmux python3; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "$cmd is required but not found"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install git, curl, tmux, and python3 first (muxa needs tmux and python3; all are used below)"
  fi
}

install_muxa() {
  if command -v muxa >/dev/null 2>&1; then
    log "muxa: $(muxa version 2>/dev/null || echo installed) — refreshing install"
  else
    log "muxa: installing from $MUXA_INSTALL_URL"
  fi

  # cwd matters. muxa is a Go project, and any go command in its installer
  # resolves its module from the *caller's* cwd. Run from command-post and go
  # walks up to this repo's .git: "cannot find main module, but found
  # .git/config in <command-post>". So run the installer from a scratch dir
  # with no repo and no go.mod above it. command-post compiles nothing, never
  # invokes go, and must not gain a go.mod — muxa ships its own broker binary.
  local scratch rc=0
  scratch="$(mktemp -d)"
  (cd "$scratch" && curl -fsSL "$MUXA_INSTALL_URL" | MUXA_BIN_DIR="$BIN" bash) || rc=$?
  rmdir "$scratch" 2>/dev/null || true
  if [[ "$rc" -eq 0 ]]; then
    check_muxa_broker
    return 0
  fi

  die "muxa install failed (could not fetch or run $MUXA_INSTALL_URL). Check network, or set MUXA_INSTALL_URL."
}

# muxa >=0.3 `muxa send` needs muxa-broker next to the realpath of bin/muxa;
# without it sends degrade to paste-fallback. Installing it is muxa's job, so
# only report here — never build.
check_muxa_broker() {
  local muxa_bin real bin_dir broker
  # Prefer the symlink this install just wrote; only then whatever PATH has,
  # so a stale muxa elsewhere on PATH is not the one we check.
  if [[ -e "$BIN/muxa" ]]; then
    muxa_bin="$BIN/muxa"
  else
    muxa_bin="$(command -v muxa || true)"
  fi
  [[ -n "$muxa_bin" && -e "$muxa_bin" ]] || { warn "muxa-broker: no muxa at $BIN/muxa or on PATH"; return 0; }

  real="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$muxa_bin")"
  bin_dir="$(dirname "$real")"
  broker="$bin_dir/muxa-broker"

  if [[ -x "$broker" ]]; then
    ln -sfn "$broker" "$BIN/muxa-broker"
    log "muxa-broker: $broker"
    return 0
  fi

  warn "muxa-broker: missing next to $real — muxa send will paste-fallback. Update muxa (its installer ships the broker binary); do not build it here."
}

install_br() {
  if command -v br >/dev/null 2>&1; then
    log "br: already installed ($(br --version))"
    return 0
  fi

  log "br: installing from beads_rust"
  curl -fsSL "${BR_INSTALL_URL}?$(date +%s)" | bash -s -- --dest "$BIN" --skip-skills --quiet
}

install_treehouse() {
  if command -v treehouse >/dev/null 2>&1; then
    log "treehouse: already installed ($(treehouse --version 2>/dev/null || treehouse -v 2>/dev/null || echo ok))"
    return 0
  fi

  log "treehouse: installing from $TREEHOUSE_INSTALL_URL"
  # treehouse install.sh picks ~/.local/bin when it is on PATH; prepend ours.
  PATH="$BIN:$PATH" sh -c "curl -fsSL '$TREEHOUSE_INSTALL_URL' | sh"
}

verify_tool() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "$cmd not found after install (expected on PATH; check $BIN)"
  fi
  log "verified: $cmd -> $(command -v "$cmd")"
}

install_deps() {
  log "phase 1: deps (cwd $ROOT)"
  require_prereqs
  ensure_bin_dir
  install_muxa
  install_br
  install_treehouse

  # Re-scan PATH so verify sees freshly linked binaries.
  export PATH="$BIN:$PATH"
  verify_tool muxa
  verify_tool br
  verify_tool treehouse
}

write_if_absent() {
  local path="$1"
  if [[ -e "$path" ]]; then
    log "exists: $path"
    return 0
  fi
  cat > "$path"
  log "created: $path"
}

scaffold() {
  log "phase 2: scaffold"
  cd "$ROOT"

  mkdir -p data projects state
  log "dirs: data/ projects/ state/"

  write_if_absent data/projects.md <<'EOF'
# Projects

<!--
Contract: machine-local registry of repos this command post dispatches into.
Never committed. bin/install.sh creates this file when absent; do not overwrite
an existing file.

Format: | Name | Clone URL | Path | Delivery | Notes |
- Name: short slug; used as projects/<name> and as br label project:<name>
- Clone URL: git remote to fetch/clone from
- Path: always projects/<name> (relative to command-post root). This is the
  only clone treehouse may lease from. Extra clones of the same repo are
  not lease sources.
- Delivery: pr | local | pipeline (default for jobs in this repo)
- Notes: freeform; record retired extra clones so they are not leased

Who writes: the orchestrator, when a project is first cloned or when
delivery/notes change.
-->

| Name | Clone URL | Path | Delivery | Notes |
|------|-----------|------|----------|-------|
EOF

  write_if_absent data/learnings.md <<'EOF'
# Learnings

<!--
Contract: curated core. Always loaded at session start.
Budget: max ~60 lines / ~1,500 tokens. Over budget → consolidate or demote
until under before the file is saved.

Writes: inspect-then-update only. Read the whole file, classify the finding
as new / duplicate / superseding / obsoleting, then rewrite the affected
entry. Never blind-append. Duplicates fold in; superseded entries are
rewritten in place. Every write leaves the file more accurate, not merely
longer.

Entries: one line each, dated, evidence-backed. Shape:
  - YYYY-MM-DD what happened; what to do; evidence: <source>. <!--tier-->
Tiers (trailing HTML comments):
  <!--P-->            pinned — never decays
  <!--a:YYYY-MM-DD--> aging — stale at ≥30 days since last reinforcement
  <!--p:YYYY-MM-DD--> perishable — stale at ≥7 days; must name a checkable
                      expiry condition (ticket, version, dated expectation)
Reinforcement counts only on real evidence of use this session. Re-reading
memory is never reinforcement.

Scope: cross-repo / orchestration knowledge only. Project-intrinsic facts
("repo X's tests need flag Y") go to that repo's AGENTS.md via a worker PR.

Job history lives in br (closed issues), not here.

Promotion: candidates live in data/candidates.md until a curation pass
promotes ones that generalize. Capture is not promotion.

Decay: evaluated lazily at curation (session end or every ~10 jobs). Stale
entries move to data/archive.md with provenance — never delete.
-->
EOF

  write_if_absent data/candidates.md <<'EOF'
# Candidates

<!--
Contract: append-only capture of reflection candidates. Never loaded wholesale.
Who writes: the orchestrator, at job completion or failure, when a lesson was observed.
When: one dated line per candidate. Most jobs yield nothing.
What: `YYYY-MM-DD <one-line lesson>`. Failures/blockers include a one-sentence
root cause when a generalization is worth promoting.
Promotion: candidates stay here until a curation pass inspects data/learnings.md
and promotes ones that generalize. Capture is not promotion. Never blind-append
to data/learnings.md.
Do not rewrite or delete lines.
-->
EOF

  write_if_absent data/archive.md <<'EOF'
# Archive

<!--
Contract: cold tier for demoted learnings. Never loaded at session start.
Who writes: the orchestrator, during a curation pass (session end or every
~10 jobs, whichever comes first).
When: perishable entries whose named condition is expired (≥7d), or aging
entries with no reinforcement this period (≥30d), or any entry demoted to
enforce the data/learnings.md budget.
What: the original learning line plus provenance — source file, tier, date
moved, and a one-line reason. Shape:
  - YYYY-MM-DD (from data/learnings.md, <!--a:…-->, archived YYYY-MM-DD): <entry>. Reason: <why>

Never delete. Recovery is `rg` plus copy-back into data/learnings.md via
inspect-then-update.
-->
EOF

  if ! command -v br >/dev/null 2>&1; then
    die "br is not installed after phase 1 (unexpected)"
  fi
  log "br: $(br --version)"

  if [[ ! -d .beads ]]; then
    br init --prefix cp
    log "br init --prefix cp"
  else
    log "exists: .beads/"
  fi

  copy_skills_to_harness
}

# Tracked source of truth is skills/. Agent CLIs discover project skills under
# their own dirs, so install copies (never symlinks) into those gitignored
# locations. Re-run refreshes copies from skills/. Extra local skills already
# in a harness dir are left in place.
copy_skills_to_harness() {
  local src="$ROOT/skills"
  if [[ ! -d "$src" ]]; then
    log "skills: none at $src"
    return 0
  fi

  local dests=(
    ".cursor/skills" # Cursor
    ".claude/skills" # Claude Code
    ".agents/skills" # Codex
  )

  local dest skill_dir name
  for dest in "${dests[@]}"; do
    mkdir -p "$ROOT/$dest"
    for skill_dir in "$src"/*; do
      [[ -d "$skill_dir" ]] || continue
      name="$(basename "$skill_dir")"
      rm -rf "$ROOT/$dest/$name"
      cp -R "$skill_dir" "$ROOT/$dest/$name"
    done
    log "skills: copied to $dest"
  done
}

# treehouse get --lease keys off the git repo of cwd. A leftover clone at
# $HOME/<name> (e.g. ~/command-post) can hand out a worktree that fails
# bin/cp check ("belongs to another repo"). Warn; do not delete anything.
abs_git_common() {
  local d="$1" g parent
  g="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || return 1
  if [[ "$g" != /* ]]; then
    g="$d/$g"
  fi
  parent="$(cd "$(dirname "$g")" && pwd -P)"
  printf '%s/%s\n' "$parent" "$(basename "$g")"
}

warn_if_conflicting_clone() {
  local label="$1" extra="$2" canonical="$3"
  local extra_git canonical_git
  extra_git="$(abs_git_common "$extra" 2>/dev/null)" || return 0
  canonical_git="$(abs_git_common "$canonical" 2>/dev/null)" || return 0
  if [[ "$extra_git" != "$canonical_git" ]]; then
    warn "$label: $extra (git $extra_git) conflicts with canonical $canonical (git $canonical_git). Lease only from projects/<name>; retire or rename the extra clone. Do not git worktree add under projects/.worktrees/ when treehouse preflight fails."
  fi
}

warn_stale_home_clones() {
  local path name
  if [[ -e "$HOME/command-post/.git" && "$ROOT" != "$HOME/command-post" ]]; then
    warn_if_conflicting_clone "stale home clone" "$HOME/command-post" "$ROOT"
    if [[ -d "$ROOT/projects/command-post" ]]; then
      warn_if_conflicting_clone "stale home clone" "$HOME/command-post" "$ROOT/projects/command-post"
    fi
  fi
  if [[ -d "$ROOT/projects" ]]; then
    local home_abs root_abs
    root_abs="$(cd "$ROOT" && pwd -P)"
    for path in "$ROOT/projects"/*; do
      [[ -d "$path" ]] || continue
      name="$(basename "$path")"
      if [[ -e "$HOME/$name/.git" ]]; then
        home_abs="$(cd "$HOME/$name" && pwd -P)"
        # Orchestrator home at ~/command-post plus projects/command-post is
        # the intended layout when shipping this repo. Skip that pair.
        [[ "$home_abs" == "$root_abs" ]] && continue
        warn_if_conflicting_clone "stale home clone" "$HOME/$name" "$path"
      fi
    done
  fi
}

main() {
  install_deps
  scaffold
  warn_stale_home_clones
  log "done — once after clone. Session start: read data/learnings.md, br ready"
}

main "$@"
