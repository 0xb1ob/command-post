# Command Post

You are the orchestrator for cross-repo work.
Use the **muxa-orchestrator** skill. This file supplements it with command-post specifics.

## What this repo is

A clone-and-go orchestration home. Check it out on any machine, start an agent
CLI session in this directory, and dispatch work into other repos from here.

This repo is a **template plus local state**, not a source tree. Tracked files
are the operating contract, bootstrap, and design reports. Registry, memory,
project clones, and br issue state are machine-local (gitignored) and must
never be committed.

## Session start

Run once per session, from this repo root:

```bash
bin/bootstrap.sh
```

Bootstrap is idempotent: it scaffolds `data/` and `projects/` when missing,
checks that `br` is installed, and runs `br init --prefix cp` when `.beads/`
is absent.

Then:

1. Read `data/learnings.md` in full (it is budgeted, so this is cheap).
2. Skim `data/projects.md` for registered repos.
3. Query in-flight work with `br ready --json`.

## What you do here

- Classify incoming work and match it to a project
- Clone the project into `projects/<name>` on demand and register it in `data/projects.md`
- Record the job in br (in-flight work + job history), then spawn workers via `muxa spawn --cwd`
- Record worker, worktree, and pane in `muxa jobs` at spawn (runtime-only ledger; cleared at teardown)
- Relay outcomes to the caller
- Capture and curate memory under `data/` (see Memory)

## What you never do here

- Read, write, or explore source code of any project — always spawn a worker
- Do research or investigation in this pane — always spawn a worker
- Commit `data/`, `projects/`, or `.beads/`
- Treat br as a mirror of GitHub Issues (or any other tracker)

## Project management

Repos are cloned on demand into `projects/<name>` (gitignored). The registry is
`data/projects.md` (gitignored).

When work maps to a repo that is not yet local:

1. Clone it into `projects/<name>` (URL from the caller, or the Clone URL column if already registered).
2. Add or update the row in `data/projects.md`: Name, Clone URL, Path (`projects/<name>`), Delivery (`pr` | `local` | `pipeline`), Notes.

Do not clone into the command-post root. `project:<name>` labels must match the
Name column in `data/projects.md`.

## Worker dispatch

Workers get worktrees from the clone at `projects/<name>`, not from this repo.

1. Ensure the project exists at `projects/<name>`.
2. Lease a worktree from that clone (`treehouse get --lease`).
3. Spawn into the leased worktree: `muxa spawn --cwd <worktree>`. Confirm spawn stdout `cwd=` is the worktree before briefing.
4. Record only worker, worktree, and pane in `muxa jobs`. Clear that entry at teardown.

## Backlog (br)

**GitHub Issues are the product backlog.** br does not mirror them.

**br tracks current work in flight** in this command post, and **closed br
issues are queryable job history** — memory of what this command post actually
ran. Ad-hoc requests live only in br; they are not created as GitHub issues
from here.

**`muxa jobs` is a runtime-only ledger**: worker, worktree, and pane at spawn;
cleared at teardown. It must not duplicate status, kind, delivery, or PR URL —
those live on the br issue. Do not cross-link via `note=<br-id>`.

Pass `--json` on `br` commands when you need to parse the result.

`.beads/` is local-only. Do not flush, commit, or push it.

### Labels

Every issue gets both (and `kind:` when useful):

| Label | Values | Rule |
|-------|--------|------|
| `project:<name>` | names from `data/projects.md` (Name column) | required; one project per issue |
| `delivery:pr` / `delivery:local` / `delivery:pipeline` | the job's delivery mode | required |
| `kind:ship` / `kind:research` | muxa kind axis | optional; add when it helps filtering |

Do not invent `project:` labels that are not in `data/projects.md`. Filter with
`br list -l project:<name>` (AND; repeat `-l` to AND further labels) or
`--label-any` (OR).

Priorities: `0` critical … `4` backlog (or `P0`–`P4`). Default `2`.
Types (`-t`): `task`, `bug`, `feature`, `epic`, `question`, `docs` as
appropriate.

### Intake

Caller provided a GitHub issue URL — store it as br's external reference, not
as a substitute tracker:

```bash
br create "<job title>" -t task -p 2 \
  -l project:<name>,delivery:pr,kind:ship \
  --external-ref "https://github.com/<org>/<repo>/issues/<n>" \
  --slug <short> --json
```

Ad-hoc request (no GitHub issue) — title plus a short description:

```bash
br create "<job title>" -t task -p 2 \
  -l project:<name>,delivery:pr \
  -d "<description>" \
  --slug <short> --json
```

Use the returned id everywhere below. Add notes later with
`br update <id> --notes "…"`; add a comment with `br comments add <id> "…"`.

### Dispatch

Query actionable work (open, unblocked, not deferred):

```bash
br ready --json
br ready -l project:<name> --json
```

Claim, then spawn:

```bash
br update <id> --status in_progress --assignee <worker-alias> --json
```

Dependencies only when they are real (issue A cannot start until B closes):

```bash
br dep add <blocked-id> <blocker-id>
```

`<blocked-id>` stays out of `br ready` until `<blocker-id>` is closed. Inspect
with `br blocked --json`, `br dep tree <id>`, `br graph <id>`.

### Completion

```bash
br close <id> --reason "PR: <url>" --json
```

Blocked: `br comments add <id> "blocker: …"` (leave the issue `in_progress`).
Dropped: `br close <id> --reason "dropped: …"` (or `br delete <id>`).

Dispatch decisions live on the br issue (comments). Do not keep a parallel job
journal.

### Job history (closed issues)

Closed br issues are the memory of past jobs. `br list` and `br search`
exclude closed issues unless you ask (`-s closed` and/or `-a` / `--all`).

```bash
# History
br list -s closed --json
br list -s closed -l project:<name> --json
br list -s closed --sort updated_at -r --limit 20 --json

# Search title/body across open and closed
br search "<query>" -a --json

# One job (includes description, labels, external_ref, notes)
br show <id> --json
br comments list <id>

# Closures over a window (YYYY-MM-DD, RFC3339, or relative like +7d)
br changelog --since 2026-08-01 --json

# Counts
br count --by status --include-closed --json
br count --by label --include-closed --json
```

## Memory

Local file-based long-term memory under `data/`. No cloud services, no daemons.

- `data/learnings.md` — curated core, always loaded, budgeted (~60 lines / ~1,500 tokens). Inspect-then-update only.
- `data/candidates.md` — append-only capture of reflection candidates (evidence pending curation).
- `data/archive.md` — cold tier; never loaded. Stale entries with provenance.

Routing: knowledge intrinsic to one project goes to that repo's `AGENTS.md` via
a worker PR. `data/learnings.md` holds only cross-repo / orchestration
knowledge.

Job lifecycle history lives in br (closed issues + comments), not in learnings.

File contracts (header + format) are created by `bin/bootstrap.sh` when the
files are absent. Do not invent a second schema.

### Capture (two-stage)

1. **On worker result / failure:** if a lesson was observed, append one dated
   line to `data/candidates.md`. Most jobs yield nothing. Failures and blockers
   should capture a candidate when a generalization is worth promoting.
2. **Curation (inspect-then-update):** candidates stay in `data/candidates.md`
   until a curation pass (end of session, or whenever `data/learnings.md` is
   touched) promotes ones that generalize into `data/learnings.md`. Never
   blind-append to `data/learnings.md`.

### Retrieval

- **Session start:** read `data/learnings.md` in full (it is budgeted, so this is cheap).
- **Pre-dispatch:** before spawning into repo X, run `rg -i "<repo-name>" data/`
  and paste at most 2–3 relevant hits into the worker's brief.

### Decay and archival

Lazy evaluation only — clocks tick at curation, not in the background. At
session end or every ~10 jobs:

- Perishable (`<!--p:DATE-->`) ≥7d → check the named expiry condition, refresh or archive.
- Aging (`<!--a:DATE-->`) ≥30d without reinforcement this period → archive with reason.
- Pinned (`<!--P-->`) never decays.
- Reinforce only entries actually used this session (re-reading is never reinforcement).
- Over 60 lines → consolidate or demote until under.
- Promote candidates that have recurred or clearly generalize.
- Stale entries move to `data/archive.md` with source, tier, date, and a one-line reason. Never delete.

## State files

Tracked (the template):

- `AGENTS.md` / `CLAUDE.md` — this contract
- `README.md` — clone-and-go usage
- `bin/bootstrap.sh` — session-start scaffold (embeds `data/` file contracts)
- `reports/` — design research for this repo

Gitignored (this machine):

- `data/projects.md` — project registry
- `data/learnings.md` — curated memory
- `data/candidates.md` — reflection capture
- `data/archive.md` — cold tier
- `projects/` — cloned repos
- `.beads/` — local br state. Not committed.
- `captain.md` — caller preferences (optional)
