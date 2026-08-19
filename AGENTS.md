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
- Track in-flight spawns in `muxa jobs` (runtime dispatch ledger)
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
- `.beads/` — durable backlog (`br` / beads_rust). SQLite (`*.db`) is gitignored; `issues.jsonl` is committed.
- `backlog.md` — pointer at the br workflow (not a second queue)
- `learnings.md` — operational knowledge across sessions
- `captain.md` — caller preferences (optional)

## Backlog

**br is the durable backlog** (source of truth for what work exists, priority, labels, and outcome).
**`muxa jobs` is the runtime dispatch ledger** (worktree paths, worker aliases, per-spawn mechanics).
Link them by putting the br issue id in the muxa job `note=`.

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
muxa jobs add <job> kind=ship delivery=pr note=<id>
```

### Completion

```bash
br close <id> --reason "PR: <url>"
muxa jobs done <job> pr=<url>
```

Blocked: `br comments add <id> "blocker: …"` (leave the issue `in_progress`).
Dropped: `br close <id> --reason "dropped: …"` (or `br delete <id>`).

### End-of-session flush

br never runs git. After mutations, persist JSONL and push so the next lease can rebuild the db:

```bash
br sync --flush-only && git add .beads/ && git commit -m "backlog sync" && git push
```

### Restart / new lease

Auto-import runs on first `br` command. To force: `br sync --import-only`.
Concurrent mutations: `br sync --merge`.
