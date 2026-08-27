#!/usr/bin/env bash
# Idempotent command-post setup. No arguments.
# Phase 1 (deps): muxa (single binary; broker via `muxa broker`), br
# (beads), treehouse — skip if already on PATH. Nothing here compiles.
# Phase 2 (scaffold): data/, projects/, data/*.md templates, br init --prefix cp,
# copy tracked skills/ into gitignored agent-harness skill dirs.
# Run once after clone; safe to re-run (muxa refreshes skills/hooks; skill copies refresh).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${CP_BIN_DIR:-$HOME/.local/bin}"

# The command-post CLI is itself named `cp` and lands in $BIN, which is on PATH
# ahead of /bin. Every POSIX copy in this script must therefore be explicit.
COPY="$(command -v /bin/cp || command -v /usr/bin/cp)"
[[ -x "$COPY" ]] || { echo "[install] fatal: no POSIX cp found" >&2; exit 1; }

MUXA_VERSION_PIN="1.0.19"
CP_VERSION_PIN="0.1.0"
BR_VERSION_PIN="v0.5.2"
BR_VERSION="${BR_VERSION_PIN#v}"

MUXA_INSTALL_URL="${MUXA_INSTALL_URL:-https://raw.githubusercontent.com/0xb1ob/muxa/${MUXA_VERSION_PIN}/install.sh}"
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
  for cmd in git curl tmux; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      warn "$cmd is required but not found"
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    die "install git, curl, and tmux first (muxa needs tmux)"
  fi
}

muxa_version_matches() {
  command -v muxa >/dev/null 2>&1 || return 1
  local ver
  ver="$(muxa version 2>/dev/null | awk '{print $1}')"
  [[ "$ver" == "$MUXA_VERSION_PIN" ]]
}

muxa_installed_ok() {
  muxa_version_matches
}

install_muxa() {
  if muxa_installed_ok; then
    log "muxa: already installed ($(muxa version 2>/dev/null | head -1))"
    verify_muxa
    return 0
  fi
  if command -v muxa >/dev/null 2>&1; then
    log "muxa: installing pinned ${MUXA_VERSION_PIN} (found $(muxa version 2>/dev/null | head -1))"
  else
    log "muxa: installing muxa ${MUXA_VERSION_PIN} from $MUXA_INSTALL_URL"
  fi

  # cwd matters. muxa is a Go project, and any go command in its installer
  # resolves its module from the *caller's* cwd. Run from command-post and go
  # walks up to this repo's .git: "cannot find main module, but found
  # .git/config in <command-post>". So run the installer from a scratch dir
  # with no repo and no go.mod above it. command-post compiles nothing, never
  # invokes go, and must not gain a go.mod — muxa ships a release binary.
  local scratch rc=0
  scratch="$(mktemp -d)"
  (cd "$scratch" && curl -fsSL "$MUXA_INSTALL_URL" | MUXA_BIN_DIR="$BIN" MUXA_BROKER_VERSION="$MUXA_VERSION_PIN" bash) || rc=$?
  rmdir "$scratch" 2>/dev/null || true
  if [[ "$rc" -eq 0 ]]; then
    verify_muxa
    return 0
  fi

  die "muxa install failed (could not fetch or run $MUXA_INSTALL_URL). Check network, or set MUXA_INSTALL_URL."
}

# muxa is one binary; the paste broker is `muxa broker start` (muxa's installer
# stops a live daemon before replacing the binary, then starts it again in tmux).
verify_muxa() {
  local muxa_bin
  # Drop stale separate-broker symlink from older muxa (<1.0.5).
  [[ -L "$BIN/muxa-broker" ]] && rm -f "$BIN/muxa-broker"

  if [[ -e "$BIN/muxa" ]]; then
    muxa_bin="$BIN/muxa"
  else
    muxa_bin="$(command -v muxa || true)"
  fi
  [[ -n "$muxa_bin" && -x "$muxa_bin" ]] || {
    warn "muxa: not found at $BIN/muxa or on PATH"
    return 0
  }
  log "muxa: $("$muxa_bin" version 2>/dev/null || echo installed) -> $muxa_bin"
  if ! muxa_version_matches; then
    warn "muxa: version mismatch (want ${MUXA_VERSION_PIN}, got $("$muxa_bin" version 2>/dev/null | awk '{print $1}'))"
    return 1
  fi
  if [[ -n "${TMUX:-}" || -n "${MUXA_TMUX_SOCKET:-}" ]]; then
    if ! "$muxa_bin" broker status >/dev/null 2>&1; then
      warn "muxa broker: not running — start with: muxa broker start"
    fi
  fi
}

ensure_muxa_hooks() {
  local hook="$ROOT/scripts/muxa-hook.sh"
  [[ -f "$hook" ]] || {
    warn "muxa hooks: missing $hook (tracked scripts/muxa-hook.sh)"
    return 0
  }
  chmod +x "$hook"
  for cfg in .claude/settings.json .cursor/hooks.json; do
    if [[ -f "$ROOT/$cfg" ]]; then
      log "muxa hooks: $cfg"
    else
      warn "muxa hooks: missing $cfg"
    fi
  done
}

cp_platform() {
  local os arch
  case "$(uname -s)" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

cp_version_matches() {
  command -v cp >/dev/null 2>&1 || return 1
  local ver
  ver="$(cp version 2>/dev/null | awk '{print $2}')"
  [[ "$ver" == "$CP_VERSION_PIN" ]]
}

install_cp() {
  local plat asset url dest
  if cp_version_matches; then
    log "cp: already installed ($(cp version 2>/dev/null | head -1))"
    return 0
  fi
  plat="$(cp_platform)" || die "cp: unsupported platform $(uname -s)/$(uname -m)"
  asset="cp-${plat}"
  if [[ -n "${CP_INSTALL_URL:-}" ]]; then
    url="$CP_INSTALL_URL"
  else
    url="https://github.com/0xb1ob/command-post/releases/download/v${CP_VERSION_PIN}/${asset}"
  fi
  dest="$BIN/cp"
  log "cp: installing ${CP_VERSION_PIN} (${asset}) from release"
  curl -fsSL "$url" -o "$dest" || {
    if [[ -x "$ROOT/bin/.cp-bin" ]] && "$ROOT/bin/.cp-bin" version >/dev/null 2>&1; then
      log "cp: release fetch failed; using checkout binary at $ROOT/bin/.cp-bin"
      "$COPY" "$ROOT/bin/.cp-bin" "$dest"
    else
      die "cp install failed (could not fetch $url). Set CP_INSTALL_URL or build with: go build -o bin/.cp-bin ./cmd/cp"
    fi
  }
  chmod +x "$dest"
  if ! cp_version_matches; then
    die "cp: version mismatch after install (want ${CP_VERSION_PIN})"
  fi
}

br_version_matches() {
  command -v br >/dev/null 2>&1 || return 1
  [[ "$(br --version 2>/dev/null)" == "br ${BR_VERSION}" ]]
}

br_home_db() {
  printf '%s/.beads/beads.db' "$ROOT"
}

br_home_list_json_ok() {
  local db
  db="$(br_home_db)"
  [[ -f "$db" ]] || return 0
  br --db "$db" list --json >/dev/null 2>&1
}

br_installed_ok() {
  br_version_matches && br_home_list_json_ok
}

install_br() {
  if br_installed_ok; then
    log "br: already installed ($(br --version))"
    return 0
  fi
  if command -v br >/dev/null 2>&1; then
    log "br: installing pinned ${BR_VERSION_PIN} (found $(br --version))"
  else
    log "br: installing beads_rust ${BR_VERSION_PIN}"
  fi
  curl -fsSL "${BR_INSTALL_URL}?$(date +%s)" | bash -s -- --dest "$BIN" --skip-skills --quiet --version "$BR_VERSION_PIN"
  export PATH="$BIN:$PATH"
  local db
  db="$(br_home_db)"
  if [[ -f "$db" ]] && ! br --db "$db" list --json >/dev/null 2>&1; then
    die "br ${BR_VERSION_PIN} installed but home tracker schema mismatch — run: br --db $(printf %q "$db") doctor migrate-schema plan"
  fi
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
  install_cp
  install_br
  install_treehouse

  # Re-scan PATH so verify sees freshly linked binaries.
  export PATH="$BIN:$PATH"
  verify_tool muxa
  verify_tool cp
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

  mkdir -p data projects state data/models
  log "dirs: data/ projects/ state/ data/models/"

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

  write_if_absent data/routing.tsv <<'EOF'
# role  argv (remaining fields joined as the command vector)
researcher	agent	--model	cursor-grok-4.6-high-fast
implementer	agent	--model	composer-2.5-fast
gate-reviewer	agent	--model	composer-2.5-fast
# forbid  <argv0>
# forbid  claude
EOF

  write_if_absent data/models.conf <<'EOF'
# allow: comma list of families from share/families.tsv
allow=cursor,grok,anthropic
# prefer.<cli_kind>: ordered family preference per CLI kind
prefer.cursor=cursor,grok,anthropic
prefer.claude=anthropic
ttl_sec=86400
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

  install_share_data
  copy_skills_to_harness
  ensure_muxa_hooks

  # Best-effort catalog fill; clone-and-go must not fail if the CLI is offline
  # or if the pinned release predates `cp models` (v0.1.0 does).
  if [[ -x "$ROOT/bin/cp" ]]; then
    "$ROOT/bin/cp" models refresh --quiet >/dev/null 2>&1 || true
  fi
}

# The release binary resolves share/ relative to its own install prefix
# ($BIN/../share), not CP_HOME. A clone-and-go install ships only the binary,
# so the CLI registry has to be placed there too or dispatch fails with
# "missing CLI registry".
install_share_data() {
  local dest="${BIN%/bin}/share"
  [[ "$dest" == "$BIN" ]] && dest="$(dirname "$BIN")/share"
  [[ -d "$ROOT/share" ]] || {
    warn "share: missing $ROOT/share"
    return 0
  }
  mkdir -p "$dest"
  local f
  for f in "$ROOT"/share/*.tsv; do
    [[ -f "$f" ]] || continue
    "$COPY" "$f" "$dest/$(basename "$f")"
  done
  log "share: registries -> $dest"

  # templates/ is resolved the same prefix-relative way (gate rubric, briefs).
  local tdest
  tdest="$(dirname "$dest")/templates"
  if [[ -d "$ROOT/templates" ]]; then
    mkdir -p "$tdest"
    for f in "$ROOT"/templates/*; do
      [[ -f "$f" ]] || continue
      "$COPY" "$f" "$tdest/$(basename "$f")"
    done
    log "templates: -> $tdest"
  else
    warn "templates: missing $ROOT/templates"
  fi
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
      "$COPY" -R "$skill_dir" "$ROOT/$dest/$name"
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
