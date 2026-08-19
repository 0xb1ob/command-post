#!/usr/bin/env bash
# Idempotent command-post scaffold. No arguments.
# Creates machine-local data/ + projects/, checks br, inits .beads/ with prefix cp.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

write_if_absent() {
  local path="$1"
  if [[ -e "$path" ]]; then
    echo "[bootstrap] exists: $path"
    return 0
  fi
  cat > "$path"
  echo "[bootstrap] created: $path"
}

mkdir -p data projects
echo "[bootstrap] dirs: data/ projects/"

write_if_absent data/projects.md <<'EOF'
# Projects

<!--
Contract: machine-local registry of repos this command post dispatches into.
Never committed. Bootstrap creates this file when absent; do not overwrite
an existing file.

Format: | Name | Clone URL | Path | Delivery | Notes |
- Name: short slug; used as projects/<name> and as br label project:<name>
- Clone URL: git remote to fetch/clone from
- Path: always projects/<name> (relative to command-post root)
- Delivery: pr | local | pipeline (default for jobs in this repo)
- Notes: freeform

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
  echo 'br is not installed. Run: bin/install.sh' >&2
  exit 1
fi
echo "[bootstrap] br: $(br --version)"

if [[ ! -d .beads ]]; then
  br init --prefix cp
  echo "[bootstrap] br init --prefix cp"
else
  echo "[bootstrap] exists: .beads/"
fi

echo "[bootstrap] done"
