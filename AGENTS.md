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

The pipeline required zero muxa changes (artifact store, gate, and playbook are all command-post; blob-store and roles deliberately NOT muxa's — see the two tests).

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

- Classify (kind + delivery; pipeline vs single), match a project, clone into `projects/<name>` and register it
- Record the job in br, then [Pre-dispatch](#pre-dispatch)
- `bin/cp dispatch` — [First brief](#first-brief) lives in templates/; not muxa-parent's slim template, not a later `muxa send`
- Relay outcomes; capture memory under `data/` (see Memory)

Never: read/write/explore project source; research or fetch URLs here (confirming a
worker PR URL is allowed); commit `data/`, `projects/`, or `.beads/`; treat br as a
GitHub Issues mirror; add MCP tools for muxa; poll or restart a worker unasked; do
the worker's job because it looks small. Pane facts: [Two hard constraints](#two-hard-constraints).

The parent may read only muxa state, worker mail, and `git status` / `git log` for preflight. Never artifact bodies.

## Classify

Before dispatch, on both axes — do not blur them.

- **kind** — `ship` (changes code) or `research` (reads and reports; changes nothing)
- **delivery** — `pr`, `local`, or `pipeline`

Persist on the br issue (`delivery:` required; `kind:` when it helps filtering), not
on `bin/cp jobs`. Evidence is not authorization: a research/scout result never starts
implementation; a ship job needs its own caller authorization.

## Pipeline (research → gate → implement)

Trigger: the parent auto-classifies at intake. Pipeline when the task is
ambiguous, multi-file, cross-cutting, or the caller does not know where the
problem lives; single worker otherwise. The caller can force either way. Do
not split small jobs.

Exactly three roles — researcher, implementer, gate-reviewer. Do not add
roles; the chosen delivery path owns the rigor. Ship authorization is at
intake; gate pass is quality only, never authorization.

1. Two br issues (`kind:research`, `kind:ship`, both delivery per intake). Dep-link: `br dep add <ship-id> <research-id>`.
2. Researcher: `bin/cp dispatch --project NAME --br-id <research-id> --template research --task-file F --` frontier CLI ([Model routing](#model-routing)). Predeclared artifact: `state/artifacts/<research-id>/report.md` (`bin/cp artifact path`).
3. Wait for the envelope ([muxa] mail; [templates/README.md](templates/README.md)). HARD RULE: workers never mail the findings body. A body in mail is a contract violation — do not act on it; capture a candidate.
4. On envelope: `bin/cp artifact add <research-id> <artifact-path>` (body → br comments; parent never reads it), then `bin/cp gate <research-id>`.
5. Verdicts (`bin/cp gate`: exit 0 pass, 10 revise, 20 escalate). Stdout JSON
   includes `cause` on every verdict (`null` on pass/revise; `policy` or
   `operational` on escalate — branch on this, not the reason prose):
   - **pass:** `br close <research-id>` with the verdict in `--reason`; the ship issue leaves `br ready`'s blocked state; `bin/cp teardown <research-id>`; `bin/cp artifact get <research-id> > tmpfile`; `bin/cp dispatch --project NAME --br-id <ship-id> --template ship --task-file tmpfile --` implementer CLI.
   - **revise:** `muxa send` the researcher the reviewer's revisions. The tool enforces one revision max — a second revise becomes escalate. Researcher stays alive until pass.
   - **escalate (`cause: policy`):** surface the envelope + verdict (short) to the caller and stop. Body on demand via `bin/cp artifact get`. Rubric flags (`destructive_scope`, `scope_growth`, `blocking_unknowns`), attempt cap after one revise, or reviewer verdict escalate.
   - **escalate (`cause: operational`):** reviewer output unparseable after one retry — re-run `bin/cp gate` immediately; do not surface to the caller as a blocker.

Context safety: the parent never reads artifact bodies. Never run `br show` /
`br comments list` on artifact-bearing issues — `br show --json` inlines full
comment bodies (PR #42). `bin/cp artifact get` redirected to a file is the
only sanctioned reader.

Retry: implementer dirty/red → re-dispatch a fresh pane with the SAME brief
(`artifact get` again); never re-run research for an implementation failure.
Gate revise loop is bounded by the tool. Never-ready (`[muxa] from=broker`)
handling is unchanged. Hung researcher (artifact exists at the predeclared
path, no envelope) → parent may `artifact add` + `gate` from that path.

## Pre-dispatch

**Path:** `bin/cp dispatch` — lease-bind, branch=br-id, `bin/cp check`,
`bin/cp jobs add`, one-tail receipt. Occupied-cwd warning is muxa's
(`muxa dispatch --cwd`, same as `muxa spawn --cwd`). `bin/cp check` fail-closes
clone/worktree facts and promote-not-spawn; it does not dispatch, send mail, or
write `bin/cp jobs`. Do not reimplement `muxa dispatch`.

`bin/cp` unavailable: lease from `projects/<name>`; bind the printed path; `bin/cp check --project NAME "$worktree"`; `muxa dispatch --cwd "$worktree" --brief-file`; `bin/cp jobs add`. Do not retype the path. Policy: [Promote vs new lease](#promote-vs-new-lease). `bin/cp check` reads `muxa who --json` (`state=idle|busy|ghost`; idle|busy → promote; ghost → `muxa kill NAME|ID` or restart CLI; else fail-closed).

### Promote vs new lease

Promote = same worker, same worktree, **same model** (includes the pipeline
revise loop). A cross-model role hop (researcher → implementer) is teardown
+ fresh dispatch, never a promote.

```
same repo AND same worktree still held (lease not returned) AND same model
  → muxa send <existing-alias> with a new brief (promote)
  → do not muxa dispatch, do not treehouse get --lease

worktree was returned, OR the job is independent
  (different repo, or a second worktree on the same repo)
  → treehouse get --lease from projects/<name>
  → bind the printed path; muxa dispatch --cwd "$worktree" (sequentially, or --name)
```

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
`bin/cp dispatch` is that command (it calls `muxa dispatch`).

### Model routing

| Role | Default |
| --- | --- |
| researcher | `agent --model cursor-grok-4.6-high-fast` (frontier) |
| implementer | `agent --model composer-2.5-fast` |
| gate-reviewer | `composer-2.5-fast` (inside `bin/cp gate`; `--model` / `CP_GATE_CMD`) |

Per-job override allowed. The operator currently forbids the claude CLI for workers.

### First brief

Contract: [templates/](templates/README.md) (`brief-ship.md` is the old inline
body; placeholder table there). `bin/cp dispatch --template` substitutes.
This contract **wins** over muxa-parent's slim dispatch template. Pass it with
`--brief-file` (stdin also works); never a positional string.

`bin/cp dispatch` stdout is `{br_id,worker,worktree,branch,state,receipt}`. Exit 0 and `state: dispatched`
mean the pane exists and the brief is queued, not received. `state=dispatched` + `receipt=unconfirmed`/`unknown`
is a VALID success — wait for mail; never re-dispatch. `state=dispatched → queued`.

Receipt is kind-aware (`muxa who --json` kind, never the agent CMD or pane text). Cursor: one `muxa tail NAME`
for the token `Branch: ${branch}` (`bin/cp dispatch` sets branch=br-id) or the bare branch in the footer.
Claude: never the bare branch (footer always shows cwd+branch — false positive) or the token (claude
consumes the brief — false negative); use footer `Context: N%`, nonzero once consumed, else `receipt=unknown`
— one check can't split a drop from claude's slow boot, so it never claims not-received. Do not loop tail.
No signal and no `[muxa] from=broker` yet → wait for mail; do not re-dispatch.
Rationale: [reports/dispatch-hardening.md](reports/dispatch-hardening.md#first-brief-receipt).

Follow-up mail (promote, or a second message to a running worker) is still `muxa send`.
If that send matters for a later failure turn, `muxa send --json` returns `{"id","pane","from","to"}`.

### Never ready (`[muxa] from=broker`)

A `[muxa] from=broker` turn means the child never became ready — the brief was not
pasted (no timeout-fallback). Ordinary mail; wake on it. Correlate with dispatch JSON `br_id` / `worker` / `worktree`. This repo's policy, not muxa's: do not retry, do not `muxa send` into the cold pane, do not
treat dispatch JSON as a successful brief. From outside the worktree run
`bin/cp teardown <br-id>` (branch still at the dispatch cut; no manual
`treehouse return` / `jobs done` / `muxa kill` sequence) and report the failure.
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

**Path:** `bin/cp teardown <br-id>` — clean+pushed verify, `treehouse return --force`
from outside the worktree, `muxa kill NAME|ID`, `bin/cp jobs done`, drops
`state/artifacts/<id>`. Does not close the br issue (PR URL on `br close`).

Fail-closed, and **you** are the actor. Dirty or unpushed keeps the lease; fix
the blocker at the path they gave you. Parent only; finished worker only; outside the worktree.
Not a licence to inspect, poll, or kill a worker still on a job.
Interactive `treehouse return` prompts — use `--force` after the worker's
clean-and-pushed gate ([why](reports/dispatch-hardening.md#teardown)).

`bin/cp` unavailable:

```bash
treehouse return --force <worktree>
muxa kill NAME
```

then `bin/cp jobs done <br-id>` (no `pr=`).

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
Triggers: worker result or failure (capture); gate verdicts whose reasons
generalize (especially escalate/revise); pipeline failures (lost envelope,
hung researcher, contract violations); session end; whenever
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
