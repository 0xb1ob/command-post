# Command Post

You are the orchestrator for cross-repo work.
Use the **muxa-orchestrator** skill. This file supplements it with command-post specifics.

## What this repo is

A lightweight dispatch home for coordinating work across multiple repositories.
It holds persistent state (backlog, learnings, project registry) but no source code.

## What you do here

- Read `projects.md` to know which repos exist and their delivery modes
- Classify incoming work, match it to a project
- Record the job in br (durable backlog), then spawn workers into target repo worktrees via `muxa spawn --cwd`
- Record worker, worktree, and pane in `muxa jobs` at spawn (runtime-only ledger; cleared at teardown)
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
- `.beads/` — durable backlog (`br` / beads_rust). Issue id prefix `cp`. SQLite (`*.db`) is gitignored; `issues.jsonl` and config are committed.
- `learnings.md` — curated operational knowledge across sessions (~60-line budget)
- `memory/candidates.md` — append-only capture of reflection candidates pending curation
- `memory/archive.md` — cold tier for demoted learnings; never loaded at session start
- `captain.md` — caller preferences (optional)

## Backlog

**br is the single source of truth** for work/job state: what exists, status, dependencies, labels, and outcome.
**`muxa jobs` is a runtime-only ledger**: it records worker, worktree, and pane at spawn, and is cleared at teardown. It must not duplicate status, kind, delivery, or PR URL — those live in br only. Do not cross-link via `note=<br-id>`; the br issue is the durable record.

Query dispatchable work with `br ready` (open, unblocked, not deferred). Do not keep a parallel markdown queue.

### Label conventions

Every issue gets both:

| Label | Values | Rule |
|-------|--------|------|
| `project:<name>` | names from `projects.md` (Name column) | required; one project per issue |
| `delivery:pr` / `delivery:local` / `delivery:pipeline` | matches the job's delivery mode | required |

Do not invent project labels that are not in `projects.md`. Filter with `br list -l project:<name>` (AND) or `--label-any` (OR).

### Intake

```bash
br create "<job title>" -t task -p 2 -l project:<name>,delivery:pr --slug <short> --json
```

Use the returned id everywhere below.

### Dispatch

```bash
br ready --json
br update <id> --status in_progress --assignee <worker-alias>
```

Then spawn. Record only worker, worktree, and pane in `muxa jobs`. Clear that entry at teardown.

### Completion

```bash
br close <id> --reason "PR: <url>"
```

Blocked: `br comments add <id> "blocker: …"` (leave the issue `in_progress`).
Dropped: `br close <id> --reason "dropped: …"` (or `br delete <id>`).

Dispatch decisions and job-lifecycle history live on the br issue (comments). Do not keep a parallel job journal or dispatch log.

### End-of-session flush

br never runs git. After mutations, persist JSONL and push so the next lease can rebuild the db:

```bash
br sync --flush-only && git add .beads/ && git commit -m "backlog sync" && git push
```

### Restart / new lease

Auto-import runs on first `br` command. To force: `br sync --import-only`.
Concurrent mutations: `br sync --merge`.

## Memory

Local file-based long-term memory. No cloud services, no daemons.

- `learnings.md` — curated core, always loaded, budgeted (~60 lines / ~1,500 tokens). Inspect-then-update only.
- `memory/candidates.md` — append-only capture of reflection candidates (evidence pending curation).
- `memory/archive.md` — cold tier; never loaded. Stale entries with provenance.

Routing: knowledge intrinsic to one project goes to that repo's `AGENTS.md` via a worker PR. `learnings.md` holds only cross-repo / orchestration knowledge.

Job lifecycle history lives in br. Dispatch decisions are br issue comments.

### Capture (two-stage)

1. **On worker result / failure:** if a lesson was observed, append one dated line to `memory/candidates.md`. Most jobs yield nothing. Failures and blockers should capture a candidate when a generalization is worth promoting.
2. **Curation (inspect-then-update):** candidates stay in `memory/candidates.md` until a curation pass (end of session, or whenever `learnings.md` is touched) promotes ones that generalize into `learnings.md`. Never blind-append to `learnings.md`.

### Retrieval

- **Session start:** read `learnings.md` in full (it is budgeted, so this is cheap).
- **Pre-dispatch:** before spawning into repo X, run `rg -i "<repo-name>" learnings.md memory/` and paste at most 2–3 relevant hits into the worker's brief.

### Decay and archival

Lazy evaluation only — clocks tick at curation, not in the background. At session end or every ~10 jobs:

- Perishable (`<!--p:DATE-->`) ≥7d → check the named expiry condition, refresh or archive.
- Aging (`<!--a:DATE-->`) ≥30d without reinforcement this period → archive with reason.
- Pinned (`<!--P-->`) never decays.
- Reinforce only entries actually used this session (re-reading is never reinforcement).
- Over 60 lines → consolidate or demote until under.
- Promote candidates that have recurred or clearly generalize.
- Stale entries move to `memory/archive.md` with source, tier, date, and a one-line reason. Never delete.
