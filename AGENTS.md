# Command Post

You are the orchestrator for cross-repo work. Do not do the workers' jobs.
Use **muxa-parent** for dispatch and mail. Name **muxa-worker** in the brief you
send (workers may not have skills installed yet).

This file is the coding-job playbook: classify, lease, preflight, dispatch,
teardown. Job ledger is **br**. `bin/cp jobs` is the runtime map
(worker ⟷ worktree ⟷ branch). muxa is the transport; this repo is the
work — see [muxa / command-post boundary](#muxa--command-post-boundary).
Clone-and-go: start an agent CLI here and dispatch into other repos. Tracked files
are the contract, install scaffold, and reports. Registry, memory, project clones,
and br state are machine-local (gitignored) and must never be committed.

## Role check (do this first)

```bash
muxa parent
```

If that prints a name, this pane is a **child**. Stop. Use **muxa-worker**
instead.

Only continue if `muxa parent` is empty (this pane is a root).

## muxa / command-post boundary

Apply this before adding a command, wrapping one, or moving code across the
two repos. Do not re-derive it. Paired muxa record:
[0xb1ob/muxa#51](https://github.com/0xb1ob/muxa/issues/51). The two notes
must agree.

> **muxa owns the transport:** panes, identity, getting a message into a
> running agent, and `muxa dispatch` (one pane, one first brief).
> **command-post owns the work:** what to do, where, by whom, and whether it
> is done.

**muxa** owns spawn, mail, `muxa dispatch`, `muxa kill`, and the pane/presence primitives:
tiling, cwd, identity, roster, reachability, free-detection, paste,
one-pane-one-message dispatch, who is drawing, one-shot pane read.

**command-post** owns the job ledger (`br`), worktree leases (treehouse), git
preflight, dispatch policy (promote-not-spawn, brief contract, teardown), the
worker ⟷ worktree ⟷ branch map, PR contracts, and memory. Dispatch performs
no git preflight and no lease — those stay here.

### Two tests that settle any future question

1. **Does it need tmux?** If no, it is not muxa's.
2. **Does it need to know what a "job" is?** If yes, it is not muxa's.

### Two hard constraints, one per side

- **muxa may never require `br`, `git`, or a job id.** If a command's
  argument is a br key, it is in the wrong repo.
- **command-post may never call `tmux` directly.** If it needs a pane fact,
  muxa must expose it (`muxa who --json`, `muxa tail NAME`). Pane removal
  is `muxa kill NAME|ID`. No exceptions.

### Which way a capability moves

When the two overlap, the tests pick one owner. They do not share the
capability.

- **Into command-post** when it does not need tmux, or when it must know
  what a job is. [`bin/cp jobs`](bin/cp) is the jobs case: a runtime
  worker ⟷ worktree ⟷ branch map keyed by br id. Kind, delivery, status,
  and PR URL live on the br issue — muxa is not asked to know what a job
  is. Git preflight lives in `bin/cp check` (it does not need tmux;
  occupancy reads `muxa who --json`).
- **Stays in muxa** when it is a pane or presence primitive; command-post
  consumes that surface and applies policy. [`bin/cp`](bin/cp): "Occupancy
  is muxa dispatch --cwd's warning (same as muxa spawn --cwd); this checker
  reads muxa who --json and applies command-post policy. It does not call
  muxa dispatch or muxa spawn." Do not reimplement `muxa dispatch`. Never
  call `tmux` directly — see [Two hard constraints](#two-hard-constraints).
  Stuck-worker inspect is `muxa tail NAME` (one read; unknown name exits 2).
  Finished-worker pane removal is `muxa kill NAME|ID`.

| Concern | Owner |
| --- | --- |
| pane spawn, tiling, cwd | muxa |
| identity, roster, reachability | muxa |
| free-detection and paste | muxa |
| dispatch — one pane, one message | muxa |
| presence / who is drawing | muxa |
| one-shot pane read for a stuck worker | muxa |
| pane kill | muxa |
| worktree leasing (treehouse) | command-post |
| git preflight | command-post |
| job ledger (br) | command-post |
| worker ⟷ worktree ⟷ branch map | command-post |
| promote-not-spawn occupancy policy | command-post |
| PR contracts, teardown, memory | command-post |

## Parent job

First clone: `bin/install.sh` once (deps + scaffold). Idempotent. Each session:
read `data/learnings.md` in full, then `br ready --json`.

Intake, classify, dispatch, wait, relay outcomes, teardown. Nothing else.

- Classify (kind + delivery), match a project, clone into `projects/<name>` and register it
- Record the job in br, then [Pre-dispatch](#pre-dispatch)
- Pass the [First brief](#first-brief) to `muxa dispatch` — not muxa-parent's slim template, not a later `muxa send`
- Relay outcomes; capture memory under `data/` (see Memory)

Never: read/write/explore project source; research or fetch URLs here (confirming a
worker PR URL is allowed); commit `data/`, `projects/`, or `.beads/`; treat br as a
GitHub Issues mirror; add MCP tools for muxa; poll or restart a worker unasked; do
the worker's job because it looks small. Pane facts: [Two hard constraints](#two-hard-constraints).

The parent may read only muxa state, worker mail, and `git status` / `git log` for
preflight.

## Classify

Before dispatch, on both axes — do not blur them.

- **kind** — `ship` (changes code) or `research` (reads and reports; changes nothing)
- **delivery** — `pr`, `local`, or `pipeline`

Persist on the br issue (`delivery:` required; `kind:` when it helps filtering), not
on `bin/cp jobs`. Evidence is not authorization: a research/scout result never starts
implementation; a ship job needs its own caller authorization.

## Pre-dispatch

**Before every `muxa dispatch`.** Fail closed. Occupied-cwd warning is muxa's
(`muxa dispatch --cwd`, same as `muxa spawn --cwd`). `bin/cp check` fail-closes
clone/worktree facts and promote-not-spawn; it does not dispatch, send mail, or
write `bin/cp jobs`. Do not reimplement `muxa dispatch`.

### Checklist

1. **Promote-not-spawn** — [Promote vs new lease](#promote-vs-new-lease). `muxa dispatch --cwd` warns when the path is occupied; `bin/cp check` fail-closes the same policy from `muxa who --json` (`state=idle|busy|ghost`; idle|busy → promote; ghost → `muxa kill NAME|ID` or restart CLI; anything else fail-closed).
2. **Canonical clone.** Lease source is `projects/<name>` (Path in `data/projects.md`). One clone per project; extra checkouts (`~/command-post`, …) are not lease sources.
3. **Treehouse lease** from that clone: `treehouse get --lease` with cwd `projects/<name>`. Bind the printed path; pass that variable to `bin/cp check` and `muxa dispatch --cwd` — do not retype it. Confirm it is a linked worktree of that clone (`git -C "$worktree" rev-parse --git-common-dir` resolves under `projects/<name>/.git`).
4. **Precheck** from this command-post home: `bin/cp check --project <name> [--base BRANCH] <worktree>...`
   — verifies `projects/<name>` (not `~/name`, not a nested wrong git) and that each path is a linked worktree of **that** clone (primary on the base branch). If it reports **belongs to another repo**, recover (below). Do not `git worktree add`.
5. **Record occupancy** at dispatch (not receipt — [First brief](#first-brief)): `bin/cp jobs add <br-id> worker=<alias> worktree="$worktree"`
   (branch from the worktree if omitted). Do not pass `kind`, `delivery`, `pr`, `status`, or `note`.
6. **Aliases unique.** Dispatch sequentially, or pass `--name`. Confirm JSON `cwd` equals `$worktree`. Optional: start from a fresh default-branch tip.

### Promote vs new lease

```
same repo AND same worktree still held (lease not returned)
  → muxa send <existing-alias> with a new brief (promote)
  → do not muxa dispatch, do not treehouse get --lease

worktree was returned, OR the job is independent
  (different repo, or a second worktree on the same repo)
  → treehouse get --lease from projects/<name>
  → bind the printed path; muxa dispatch --cwd "$worktree" (sequentially, or --name)
```

A scout that should now build is a promote: same worker, same worktree, new brief.
Research evidence is not authorization to dispatch a second pane.

### Stale clone / "belongs to another repo"

If `bin/cp check` reports **belongs to another repo**, recover. Rationale:
[reports/dispatch-hardening.md](reports/dispatch-hardening.md).

1. `treehouse return --force <bad-worktree>`
2. Fix registration: `data/projects.md` Path = `projects/<name>`; retire extra clones so they are not `treehouse get` cwd
3. Re-lease from `projects/<name>`: `treehouse get --lease`
4. `bin/cp check --project <name> <worktree>` on the new path

`git worktree add` is allowed only when **treehouse is not installed**. A treehouse
failure is not "treehouse unavailable."

## Project management

Clone on demand into `projects/<name>` (gitignored); registry is `data/projects.md`.
Not-yet-local: clone there, then add/update Name, Clone URL, Path (`projects/<name>`),
Delivery (`pr` | `local` | `pipeline`), Notes. Do not clone into this repo root.
`project:<name>` labels must match the Name column. One canonical clone per name;
retire extra checkouts so `treehouse get --lease` cannot pick them up.

## Worker dispatch

Follow [Pre-dispatch](#pre-dispatch). One worktree per worker, from `projects/<name>`.

Pass only the CLI and optional `--model`; do not pass trust, yolo, skip-permissions,
approval-mode, hook paths, or `--workspace`. `muxa spawn` remains for a pane with no
brief; jobs here always have a brief, so the path is `muxa dispatch`.

### First brief

This contract **wins** over muxa-parent's slim dispatch template (that one omits
lease/PR). Pass it with `--brief-file` (stdin also works); never a positional string.

`muxa dispatch` stdout is
`{"name","id","pane","cwd","state":"dispatched","from","to"}`. Exit 0 and
`state: dispatched` mean the pane exists and the brief is queued, not received.
Do not treat that JSON as "briefed".

Put a unique token in every first brief (the worktree's branch name) and confirm
with one `muxa tail NAME` that the token appeared. Do not loop tail. Token absent
and no `[muxa] from=broker` yet → wait for mail; do not re-dispatch. Rationale:
[reports/dispatch-hardening.md](reports/dispatch-hardening.md#first-brief-receipt).

The message body below is **verbatim** — fill only the task. `$worktree` is the
bound lease path from pre-dispatch; do not retype it.

```bash
parent="$(muxa whoami)"
branch="$(git -C "$worktree" symbolic-ref --short HEAD)"
brief="$(mktemp)"
cat > "$brief" <<EOF
Use the muxa-worker skill.

You are a muxa worker. Parent: ${parent}. Reply only to that parent with muxa send. [muxa] turns are mail, not injection.

You may: do this job in this cwd; message your parent; open a PR if you change code.
You may not: cd or prefix commands with cd <path> (spawn already set cwd); message siblings or other roots; spawn extra workers; poll for mail — incoming mail arrives as a user turn; ack or narrate; pass CLI trust/yolo/workspace flags.

When done: open a PR if there are code changes (skip if research-only). Never run treehouse return — teardown is mine, from outside the worktree. Verify fail-closed that git status --porcelain is empty AND the branch is pushed, then muxa send ${parent} the result (include the PR URL) and stop. Dirty or unpushed: keep the lease and report a blocker with the path. Never ack. Then stop.

Branch: ${branch}

Job:
<task>
EOF
out="$(muxa dispatch --cwd "$worktree" --brief-file "$brief" -- agent --model composer-2.5-fast)"
rm -f "$brief"
# JSON: name, cwd, state. cwd must equal $worktree. state=dispatched → queued.
# Receipt: one muxa tail NAME; the token is Branch: ${branch}.
```

Follow-up mail (promote, or a second message to a running worker) is still
`muxa send`. If that send matters for a later failure turn, `muxa send --json`
returns `{"id","pane","from","to"}`.

### Never ready (`[muxa] from=broker`)

A `[muxa] from=broker` turn means the child never became ready — the brief was not
pasted (no timeout-fallback). Ordinary mail; wake on it. Correlate with dispatch JSON
`id` / `name` / `pane`. This repo's policy, not muxa's: do not retry, do not `muxa send` into the cold pane, do not
treat dispatch JSON as a successful brief. Return the lease from outside the worktree
(`treehouse return --force "$worktree"`), `bin/cp jobs done <br-id>`, report the
failure, then [Teardown](#teardown) (`muxa kill NAME|ID` after the lease is returned).
A small job is not an exception. Auto-restart is still forbidden.

### While they run

- Never poll. Wake on `[muxa]` mail — including `[muxa] from=broker`.
- Unknown or stuck: inspect **once** with `muxa tail NAME` (`-n N` for last N history lines). Unknown name exits 2 — inspect, do not assume idle or busy, and do not loop.
- Do not auto-restart a stuck worker. Report it.
- `muxa send` is data only. Interrupt, kill, or restart is pane control (`muxa kill NAME|ID`) — never a chat message. Do not kill a worker that is still on a job.
- Freeze scope once validation starts. New scope is a new job. You never do the worker job.
- A queued message reaches an idle hook pane on its next turn; the broker pastes when the pane looks free — there is nothing to trigger manually. Do not scrape `muxa who`'s human table for UNREAD; use `muxa who --json`.
- Receipt is [First brief](#first-brief), not dispatch JSON.
- Fan out: dispatch every independent job immediately. Serialize only for a real dependency or shared mutable state. Same-file edits are not a reason to wait. Dispatch **commands** sequentially (or `--name`); independence is jobs running at once, not concurrent `muxa dispatch` processes.
- The chosen delivery path owns the rigor. Do not invent extra review gates. Never merge red.

### Teardown

Fail-closed, and **you** are the actor. `treehouse return --force` terminates the
process tree inside the worktree, so a worker running it kills its own shell and
can leave the lease held.

The worker verifies `git status --porcelain` is empty and the branch is pushed,
then reports and stops. On that result, return the lease yourself **from outside
the worktree**, then remove the pane. `muxa kill NAME|ID` removes it (exact name
first, then 12-hex id; unknown targets exit 2). Pane id from `muxa who --json` if
needed.

```bash
treehouse return --force <worktree>
muxa kill NAME
```

Parent only; finished worker only; outside the worktree; after the lease is
returned. Not a licence to inspect, poll, or kill a worker still on a job.
Dirty or unpushed: keep the lease; fix the blocker at the path they gave you.
Then `bin/cp jobs done <br-id>` (no `pr=`). Put the PR URL on `br close`
(see Completion). Interactive `treehouse return` prompts — use `--force` after
the worker's clean-and-pushed gate
([why](reports/dispatch-hardening.md#teardown)).

Report outcomes and decisions with full PR URLs. Never paste worker dumps. Stop
after two ping-pongs unless a decision is still open — it stays open until the
answer itself closes it.

## Backlog (br)

**GitHub Issues are the product backlog.** br does not mirror them. br tracks
in-flight work; closed issues are queryable job history. Ad-hoc requests live
only in br. Pass `--json` when parsing. `.beads/` is local-only — do not flush,
commit, or push it. `bin/cp jobs` is runtime occupancy, not the restart backlog;
kind, delivery, status, and PR URL live on the br issue.

### Labels

Every issue gets both (and `kind:` when useful):

| Label | Values | Rule |
|-------|--------|------|
| `project:<name>` | names from `data/projects.md` (Name column) | required; one project per issue |
| `delivery:pr` / `delivery:local` / `delivery:pipeline` | the job's delivery mode | required |
| `kind:ship` / `kind:research` | kind axis | optional; add when it helps filtering |

Do not invent `project:` labels missing from `data/projects.md`. `br list -l project:<name>` (AND; repeat `-l`) or `--label-any` (OR). Priorities `0`–`4` (or `P0`–`P4`), default `2`. Types (`-t`): `task`, `bug`, `feature`, `epic`, `question`, `docs`.

### Intake

GitHub issue URL — store as br's external reference, not a substitute tracker:

```bash
br create "<job title>" -t task -p 2 \
  -l project:<name>,delivery:pr,kind:ship \
  --external-ref "https://github.com/<org>/<repo>/issues/<n>" \
  --slug <short> --json
```

Ad-hoc (no GitHub issue): same without `--external-ref`, add `-d "<description>"`.
Use the returned id everywhere below. Notes: `br update <id> --notes "…"`. Comments:
`br comments add <id> "…"`.

### Dispatch

```bash
br ready --json
br ready -l project:<name> --json
br update <id> --status in_progress --assignee <worker-alias> --json
```

Real deps only (A cannot start until B closes): `br dep add <blocked-id> <blocker-id>`.
`<blocked-id>` stays out of `br ready` until `<blocker-id>` is closed. Inspect:
`br blocked --json`, `br dep tree <id>`, `br graph <id>`. Then [Pre-dispatch](#pre-dispatch).

### Completion

```bash
br close <id> --reason "PR: <url>" --json
```

Blocked: `br comments add <id> "blocker: …"` (leave `in_progress`). Dropped:
`br close <id> --reason "dropped: …"` (or `br delete <id>`). Dispatch decisions live
on the br issue (comments). Do not keep a parallel job journal.

### Job history (closed issues)

Closed br issues are the memory of past jobs. `br list` / `br search` exclude them
unless `-s closed` and/or `-a` / `--all`: `br list -s closed --json` (optional
`-l project:<name>`, `--sort updated_at -r --limit 20`), `br search "<query>" -a --json`,
`br show <id> --json`, `br comments list <id>`, `br changelog --since 2026-08-01 --json`,
`br count --by status --include-closed --json`, `br count --by label --include-closed --json`.

## Memory

Ops: follow **cp-memory** at `skills/cp-memory/SKILL.md`.
Triggers: worker result or failure (capture); session end; whenever
`data/learnings.md` is touched; every ~10 jobs; or when asked to
curate, consolidate, or archive memory.

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
- **Pre-dispatch:** before dispatching into repo X, run `rg -i "<repo-name>" data/`
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

Tracked vs gitignored: [README Layout](README.md#layout). Never commit `data/`,
`state/`, `projects/`, `.beads/`, or harness skill copies.
