# Command Post

Clone this repo on any machine, start an agent CLI session **inside it**, and
dispatch work across your other repositories from here.

This checkout is a **template**. The operating contract is tracked; your
project clones, memory, registry, and job history stay on this machine.

## Clone and go

```bash
git clone https://github.com/0xb1ob/command-post.git
cd command-post
```

Then open your agent CLI (Claude Code, Cursor, Codex, …) with this directory
as the workspace. On the first turn the agent runs:

```bash
bin/bootstrap.sh
```

That script is idempotent and takes no arguments. It:

1. Creates `data/` (registry + memory files with their contracts) if missing
2. Creates `projects/` if missing
3. Checks that [`br`](https://github.com/Dicklesworthstone/beads_rust) is on `PATH`
4. Runs `br init --prefix cp` if `.beads/` is absent

Ask the agent to do work (a GitHub issue URL, or an ad-hoc request). It will
clone the target repo into `projects/<name>` if needed, record it in
`data/projects.md`, track the job with `br`, lease a worktree, and spawn a
worker.

## Layout

| Path | Tracked? | Role |
|------|----------|------|
| `AGENTS.md`, `CLAUDE.md` | yes | Operating contract |
| `README.md` | yes | This file |
| `bin/bootstrap.sh` | yes | Session-start scaffold; embeds `data/` file contracts |
| `reports/` | yes | Design research for this repo |
| `data/` | **no** | `projects.md`, `learnings.md`, `candidates.md`, `archive.md` |
| `projects/` | **no** | Cloned repos, one directory per name |
| `.beads/` | **no** | Local `br` state (in-flight jobs + history) |

Do not commit `data/`, `projects/`, or `.beads/`.

## What the agent uses

- **GitHub Issues** — the real product backlog, when the caller points at one
- **`br`** — current jobs in this command post, and closed issues as job history
- **`muxa jobs`** — runtime-only (worker / worktree / pane); gone at teardown
- **`data/learnings.md`** — budgeted cross-repo memory (see `AGENTS.md`)

`br` is not a mirror of GitHub. Install it with:

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash
```

Worker dispatch also expects `muxa` and `treehouse` on `PATH`.

## Contract

Read [AGENTS.md](AGENTS.md).
