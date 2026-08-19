# Command Post

You are the orchestrator for cross-repo work.
Use the **muxa-orchestrator** skill. This file supplements it with command-post specifics.

## What this repo is

A lightweight dispatch home for coordinating work across multiple repositories.
It holds persistent state (backlog, learnings, project registry) but no source code.

## What you do here

- Read `projects.md` to know which repos exist and their delivery modes
- Classify incoming work, match it to a project
- Spawn workers into target repo worktrees via `muxa spawn --cwd`
- Track jobs in the backlog
- Relay outcomes to the caller

## What you never do here

- Read, write, or explore source code of any project
- Do research or investigation — always spawn a worker for that
- Clone or pull projects into this repo

## Worker dispatch

Workers get worktrees from the target project's repo, not from this one:

```bash
cd /path/to/target-repo
treehouse get --lease
# then spawn into that worktree
```

## State files

- `projects.md` — registry of repos (path, delivery mode, notes)
- `backlog.md` — persistent task queue
- `learnings.md` — operational knowledge across sessions
- `captain.md` — caller preferences (optional)

## Memory

Local file-based long-term memory. No cloud services, no daemons.

- `learnings.md` — curated core, always loaded, budgeted (~60 lines / ~1,500 tokens). Inspect-then-update only.
- `memory/jobs.md` — append-only job journal with reflection candidates (evidence tier).
- `memory/decisions.md` — append-only dispatch-decision log.
- `memory/archive.md` — cold tier; never loaded. Stale entries with provenance.

Routing: knowledge intrinsic to one project goes to that repo's `AGENTS.md` via a worker PR. `learnings.md` holds only cross-repo / orchestration knowledge.

### Capture (two-stage)

1. **At dispatch:** append one decision line to `memory/decisions.md`.
2. **On worker result:** append a job block to `memory/jobs.md` (date, job id, repo, outcome, PR, 0–3 candidate learnings answering: what failed or surprised, what would be done differently, what the next dispatch to this repo should know). Most jobs yield zero candidates.
3. **On failure / blocker:** mandatory post-mortem in the job block — root cause in one sentence plus a candidate learning.

Promotion is separate from capture. Candidates sit in `memory/jobs.md` until a curation pass (end of session, or whenever `learnings.md` is touched) promotes the ones that generalize into `learnings.md` via inspect-then-update. Never blind-append to `learnings.md`.

### Retrieval

- **Session start:** read `learnings.md` in full (it is budgeted, so this is cheap).
- **Pre-dispatch:** before spawning into repo X, run `rg -i "<repo-name>" learnings.md memory/` and paste at most 2–3 relevant hits into the worker's brief.
- **Post-mortems:** grep `memory/jobs.md` and `memory/decisions.md` by repo or date range.

### Decay and archival

Lazy evaluation only — clocks tick at curation, not in the background. At session end or every ~10 jobs:

- Perishable (`<!--p:DATE-->`) ≥7d → check the named expiry condition, refresh or archive.
- Aging (`<!--a:DATE-->`) ≥30d without reinforcement this period → archive with reason.
- Pinned (`<!--P-->`) never decays.
- Reinforce only entries actually used this session (re-reading is never reinforcement).
- Over 60 lines → consolidate or demote until under.
- Promote job-log candidates that have recurred or clearly generalize.
- Stale entries move to `memory/archive.md` with source, tier, date, and a one-line reason. Never delete.
