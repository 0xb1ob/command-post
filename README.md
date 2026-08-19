# Command Post

Clone this repo on any machine, start an agent CLI session **inside it**, and
dispatch work across your other repositories from here.

This checkout is a **template**. The operating contract is tracked; your
project clones, memory, registry, and job history stay on this machine.

## Clone and go

```bash
git clone https://github.com/0xb1ob/command-post.git
cd command-post
bin/install.sh      # once: muxa, br, treehouse (+ tmux/git/curl prereqs)
bin/bootstrap.sh    # each session: data/, projects/, br init
```

Then open your agent CLI (Claude Code, Cursor, Codex, …) with this directory
as the workspace. On the first turn the agent runs `bin/bootstrap.sh` (see
[AGENTS.md](AGENTS.md)).

### `bin/install.sh`

Idempotent dependency installer. Takes no arguments. It:

1. Checks prerequisites: `git`, `curl`, `tmux` (muxa requires tmux)
2. Installs [`muxa`](https://github.com/0xb1ob/muxa) onto `~/.local/bin` (refreshes skills/hooks on re-run)
3. Installs [`br`](https://github.com/Dicklesworthstone/beads_rust) (beads) with `--skip-skills`
4. Installs [`treehouse`](https://github.com/kunchenguid/treehouse) for worktree leasing

Put `~/.local/bin` on your `PATH` if it is not already. Re-run anytime; existing
`br` / `treehouse` installs are skipped, muxa is refreshed.

### `bin/bootstrap.sh`

Session-start scaffold. Idempotent, no arguments. It:

1. Creates `data/` (registry + memory files with their contracts) if missing
2. Creates `projects/` if missing
3. Checks that `br` is on `PATH` (run `bin/install.sh` if not)
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
| `bin/install.sh` | yes | One-time runtime dependency install |
| `bin/bootstrap.sh` | yes | Session-start scaffold; embeds `data/` file contracts |
| `reports/` | yes | Design research for this repo |
| `data/` | **no** | `data/projects.md`, `data/learnings.md`, `data/candidates.md`, `data/archive.md` |
| `projects/` | **no** | Cloned repos, one directory per name |
| `.beads/` | **no** | Local `br` state (in-flight jobs + history) |

Do not commit `data/`, `projects/`, or `.beads/`.

## What the agent uses

- **GitHub Issues** — the real product backlog, when the caller points at one
- **`br`** — current jobs in this command post, and closed issues as job history
- **`muxa jobs`** — runtime-only (worker / worktree); gone at teardown
- **`data/learnings.md`** — budgeted cross-repo memory (see `AGENTS.md`)

`br` is not a mirror of GitHub. Install runtime tools with `bin/install.sh`.

Worker dispatch also expects `muxa` and `treehouse` on `PATH`. Spawn and mail
use the **muxa-parent** skill; the job playbook lives in `AGENTS.md`.

## Contract

Read [AGENTS.md](AGENTS.md).
