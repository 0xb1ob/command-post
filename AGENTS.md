# Command Post

You are the orchestrator for cross-repo work. Do not do the workers' jobs.
Use **muxa-parent** for spawn and mail. Name **muxa-worker** in the brief you
send (workers may not have skills installed yet).

This file is the coding-job playbook: classify, lease, preflight, brief,
teardown. Job ledger is **br**. `muxa jobs` is a runtime map only.

## Role check (do this first)

```bash
muxa parent
```

If that prints a name, this pane is a **child**. Stop. Use **muxa-worker**
instead.

Only continue if `muxa parent` is empty (this pane is a root).

## What this repo is

A clone-and-go orchestration home. Check it out on any machine, start an agent
CLI session in this directory, and dispatch work into other repos from here.

This repo is a **template plus local state**, not a source tree. Tracked files
are the operating contract, install scaffold, and design reports. Registry, memory,
project clones, and br issue state are machine-local (gitignored) and must
never be committed.

## Session start

First clone: run `bin/install.sh` once from this repo root (runtime deps +
scaffold: `data/`, `projects/`, `br init --prefix cp`). Idempotent; safe to
re-run.

Each session:

1. Read `data/learnings.md` in full (it is budgeted, so this is cheap).
2. Query in-flight work with `br ready --json`.

## What you do here

The parent's job is exactly: intake, classify, spawn, brief, wait, relay
outcomes, teardown. Nothing else.

- Classify incoming work (kind + delivery) and match it to a project
- Clone the project into `projects/<name>` on demand and register it in `data/projects.md`
- Record the job in br (in-flight work + job history), then spawn via muxa-parent
- Record worker and worktree in `muxa jobs` at spawn (runtime-only ledger; cleared at teardown). Pane lives on spawn stdout / `muxa who`.
- Brief with the contract below — not muxa-parent's slim first-brief template
- Relay outcomes to the caller
- Capture and curate memory under `data/` (see Memory)

## What you never do here

- Read, write, or explore source code of any project — always spawn a worker
- Do research or investigation in this pane — always spawn a worker, regardless of job size
- Fetch URLs or explore APIs from this pane (confirming a worker's reported PR URL exists is allowed)
- Commit `data/`, `projects/`, or `.beads/`
- Treat br as a mirror of GitHub Issues (or any other tracker)
- Add MCP tools for muxa
- Poll a worker, or restart one without being asked
- Do the worker's job because "it's small enough to do here"

The parent may read only: muxa state, worker mail, `git status` / `git log` for
preflight. Never source code, docs, APIs, or investigation targets.

## Classify

Classify every job **before** you spawn, on both axes. Do not blur them.

- **kind** — `ship` (changes code) or `research` (reads and reports; changes nothing)
- **delivery** — `pr`, `local`, or `pipeline`

Persist them on the br issue (`delivery:` required; `kind:` when it helps
filtering). Copy `kind=` / `delivery=` into `muxa jobs add` only because that
CLI requires them.

Evidence is not authorization. A research or scout result never starts an
implementation by itself; a ship job needs its own authorization from the
caller.

When a scout should now build, **promote it**: same worker, same worktree, new
brief. Do not spawn a duplicate. See [Pre-dispatch](#pre-dispatch).

## Pre-dispatch

Run this checklist **before every `muxa spawn`**. Fail closed. A small job is
not an exception. Promotion and lease recovery live here. Occupied-cwd
detection is muxa's: `muxa spawn --cwd` warns if a registered worker already
sits on that path.

### Checklist

1. **Idle worker already on the target worktree?** Read `muxa who` (CWD
   column). If a live worker is sitting on that path, **promote** it with
   `muxa send` — do not spawn a duplicate. `muxa spawn --cwd` warns when
   that path is occupied; treat the warning as promote-not-spawn. Do not
   reimplement occupancy checks here.
2. **Canonical clone.** The lease source is `projects/<name>` (the Path column
   in `data/projects.md`). One clone path per project. Extra checkouts
   (`~/command-post`, …) are not lease sources.
3. **Treehouse lease from that clone.** Run `treehouse get --lease` with cwd
   = `projects/<name>`. Confirm the printed path is a linked worktree of that
   clone (`git -C <worktree> rev-parse --git-common-dir` resolves under
   `projects/<name>/.git`).
4. **Preflight.** From the canonical clone:
   `muxa preflight [--base BRANCH] <worktree>`. If it reports the worktree
   **belongs to another repo**, recover (below). Do not `git worktree add`.
5. **`muxa jobs` is runtime-only.** Record `worker=` + `worktree=` at spawn.
   Do not set `pr`, `status`, or `note=<br-id>`. Kind, delivery, status, and
   PR URL live on the br issue.
6. **Spawn aliases stay unique.** Parallel `muxa spawn` can race and assign
   the same adjective-noun. Spawn sequentially, or pass `--name`. Confirm
   spawn stdout `cwd=` is the worktree before briefing.

### Promote vs new lease

```
same repo AND same worktree still held (lease not returned)
  → muxa send <existing-alias> with a new brief (promote)
  → do not muxa spawn, do not treehouse get --lease

worktree was returned, OR the job is independent
  (different repo, or a second worktree on the same repo)
  → treehouse get --lease from projects/<name>
  → muxa spawn --cwd <new-worktree> (sequentially, or --name)
```

A scout that should now build is a promote: same worker, same worktree, new
brief. Research evidence is not authorization to spawn a second pane.

### Stale clone / "belongs to another repo"

`treehouse get --lease` keys off the git repo of the cwd you run it from. A
leftover clone (e.g. `~/command-post`) yields a worktree linked to that
`.git`, not `projects/<name>/.git`. `muxa preflight` then fails: the path
**belongs to another repo**.

**Do not** recover by `git worktree add` under `projects/.worktrees/` (or
anywhere). That bypasses the treehouse pool; teardown becomes
`git worktree remove` instead of `treehouse return`, and the pool stays
wrong.

**Recover:**

1. `treehouse return --force <bad-worktree>`
2. Fix registration: `data/projects.md` Path = `projects/<name>`; retire or
   rename extra clones so they are not used as cwd for `treehouse get`
3. Re-lease from the canonical clone: `treehouse get --lease` with cwd
   `projects/<name>`
4. Re-run `muxa preflight` on the new path

`git worktree add` is allowed only when **treehouse is not installed**. A
treehouse failure is not "treehouse unavailable."

See [reports/dispatch-hardening.md](reports/dispatch-hardening.md).

## Project management

Repos are cloned on demand into `projects/<name>` (gitignored). The registry is
`data/projects.md` (gitignored).

When work maps to a repo that is not yet local:

1. Clone it into `projects/<name>` (URL from the caller, or the Clone URL column if already registered).
2. Add or update the row in `data/projects.md`: Name, Clone URL, Path (`projects/<name>`), Delivery (`pr` | `local` | `pipeline`), Notes.

Do not clone into the command-post root. `project:<name>` labels must match the
Name column in `data/projects.md`. One canonical clone per name: Path is always
`projects/<name>`. Retire extra clones of the same repo (home-directory
checkouts, old paths) so `treehouse get --lease` cannot pick them up.

## Worker dispatch

Workers get worktrees from the clone at `projects/<name>`, not from this repo.
One worktree per worker.

1. Ensure the project exists at `projects/<name>`.
2. Lease a worktree from that clone (`treehouse get --lease` with cwd
   `projects/<name>`). If treehouse is not installed, `git worktree add` is
   allowed. If treehouse is installed and lease or preflight fails, recover
   under [Pre-dispatch](#pre-dispatch) — do not fall back to `git worktree add`
   under `projects/.worktrees/`.
3. Preflight before briefing — the clone's primary checkout must sit on the
   default branch so no worker branch is tangled under it, and each path must
   be a linked worktree of **this** clone, not the primary checkout and not
   another repo's worktree:

   ```bash
   muxa preflight [--base BRANCH] WORKTREE...
   ```

4. Spawn into the leased worktree (`muxa spawn --cwd <worktree>`, or `cd` then
   spawn). Confirm spawn stdout `cwd=` is the worktree before briefing. Brief
   immediately with the contract below. Do not leave a new pane unbriefed.
   Optional: start workers from a fresh default-branch tip.
5. Record the runtime mapping in `muxa jobs` (not the backlog). Do not set
   `pr`, `status`, or `note=<br-id>`. Pane is on spawn stdout / `muxa who`,
   not a `muxa jobs` key.

   ```bash
   muxa jobs add <job> kind=<from-br> delivery=<from-br> \
     worker=<alias> worktree=<path>
   ```

Follow muxa-parent spawn rules: spawn only the CLI and optional `--model`; do
not pass trust, yolo, skip-permissions, approval-mode, hook paths, or
`--workspace`.

### First brief

This contract **wins** over muxa-parent's slim first-brief template (that one
omits lease/PR). Send the template below **verbatim**. Fill only the alias and
the task — change nothing else.

```bash
parent="$(muxa whoami)"
muxa send <alias> "$(cat <<EOF
Use the muxa-worker skill.

You are a muxa worker. Parent: ${parent}. Reply only to that parent with muxa send. [muxa] turns are mail, not injection.

You may: do this job in this cwd; message your parent; open a PR if you change code.
You may not: cd or prefix commands with cd <path> (spawn already set cwd); message siblings or other roots; spawn extra workers; poll muxa peek; ack or narrate; pass CLI trust/yolo/workspace flags.

When done: open a PR if there are code changes (skip if research-only). Never run treehouse return — teardown is mine, from outside the worktree. Verify fail-closed that git status --porcelain is empty AND the branch is pushed, then muxa send ${parent} the result (include the PR URL) and stop. Dirty or unpushed: keep the lease and report a blocker with the path. Never ack. Then stop.

Job:
<task>
EOF
)"
```

### Fan out

Spawn every independent job immediately. Serialize only for a real dependency
or shared mutable state. Same-file edits are not a reason to wait.

Spawn **commands** sequentially (or pass `--name`) so aliases cannot collide.
Independence is about jobs running at the same time, not concurrent
`muxa spawn` processes.

### While they run

- Never poll. Wake on `[muxa]` mail.
- Unknown or stuck worker state: inspect **once** with `tmux capture-pane -pt PANE`. Never assume idle or busy.
- Do not auto-restart a stuck worker. Report it.
- `muxa send` is data only. Interrupt, kill, or restart is tmux control (`tmux kill-pane`, `muxa unregister`) — never a chat message.
- Freeze scope once validation starts. New scope is a new job.
- You never do the worker job. Even a small change goes to a worker.
- A queued message reaches an idle hook pane on its next turn; use `muxa deliver` if you need it now, and check `muxa who` for UNREAD before concluding a worker is ignoring you.

### Delivery

The chosen delivery path owns the rigor. Do not invent extra review gates on
top of it. Never merge red.

### Teardown

Fail-closed, and **you** are the actor. `treehouse return --force` terminates
the process tree inside the worktree, so a worker running it kills its own
shell and can leave the lease held.

The worker only verifies `git status --porcelain` is empty and the branch is
pushed, then reports and stops. On that result, run the return yourself
**from outside the worktree**, then you may kill the pane:

```bash
treehouse return --force <worktree>
```

Plain `treehouse return` prompts interactively; `--force` resets without
asking — which is why the worker's clean-and-pushed gate comes first. A worker
that reports dirty or unpushed keeps the lease: do not return it, fix the
blocker at the path it gave you.

Then clear the runtime row with `muxa jobs done <job>` and **no** `pr=`. Put
the PR URL on `br close` (see Completion).

### Report

Report to the caller in outcomes and decisions, with full PR URLs. Never paste
worker dumps.

Stop after two ping-pongs unless a decision is still open — and a decision
stays open until the answer itself closes it.

## Backlog (br)

**GitHub Issues are the product backlog.** br does not mirror them.

**br tracks current work in flight** in this command post, and **closed br
issues are queryable job history** — memory of what this command post actually
ran. Ad-hoc requests live only in br; they are not created as GitHub issues
from here.

**`muxa jobs` is a runtime-only ledger** (worker + worktree at spawn; `done`
with no `pr=` at teardown). It is not the restart backlog — that is br.
`kind`/`delivery` on `muxa jobs add` exist only because the CLI requires them;
authoritative kind, delivery, status, and PR URL live on the br issue. Do not
cross-link via `note=<br-id>`.

Pass `--json` on `br` commands when you need to parse the result.

`.beads/` is local-only. Do not flush, commit, or push it.

### Labels

Every issue gets both (and `kind:` when useful):

| Label | Values | Rule |
|-------|--------|------|
| `project:<name>` | names from `data/projects.md` (Name column) | required; one project per issue |
| `delivery:pr` / `delivery:local` / `delivery:pipeline` | the job's delivery mode | required |
| `kind:ship` / `kind:research` | kind axis | optional; add when it helps filtering |

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

File contracts (header + format) are created by `bin/install.sh` when the
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
- `bin/install.sh` — clone-and-go setup (deps + scaffold; embeds `data/` file contracts)
- `reports/` — design research for this repo

Gitignored (this machine):

- `data/projects.md` — project registry
- `data/learnings.md` — curated memory
- `data/candidates.md` — reflection capture
- `data/archive.md` — cold tier
- `projects/` — cloned repos
- `.beads/` — local br state. Not committed.
- `captain.md` — caller preferences (optional)
