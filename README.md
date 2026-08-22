# Command Post

Clone this repo on any machine, start an agent CLI session **inside it**, and
dispatch work across your other repositories from here.

This checkout is a **template**. The operating contract is tracked; your
project clones, memory, registry, and job history stay on this machine.

## Clone and go

```bash
git clone https://github.com/0xb1ob/command-post.git
cd command-post
bin/install.sh      # once: deps + scaffold (muxa, br, treehouse, data/, br init)
```

Then open your agent CLI (Claude Code, Cursor, Codex, …) with this directory
as the workspace. Each session the agent reads memory and checks in-flight
work (see [AGENTS.md](AGENTS.md)); no need to re-run `bin/install.sh`.

### `bin/install.sh`

Idempotent clone-and-go setup. Takes no arguments. It:

**Phase 1 — deps**

1. Checks prerequisites: `git`, `curl`, `tmux` (muxa requires tmux)
2. Installs [`muxa`](https://github.com/0xb1ob/muxa) onto `~/.local/bin` (refreshes skills/hooks on re-run), then checks that `muxa-broker` sits next to it — without the broker binary, `muxa send` exits non-zero and pastes nothing, and `muxa who --json` also fails (it needs the binary for JSON encoding). muxa's SPEC is fail-closed — no paste-buffer fallback. muxa's installer provides that binary; command-post never compiles it. The installer runs from a scratch dir, so a Go toolchain can never mistake this repo (no `go.mod`, and it must not gain one) for muxa's module.
3. Installs [`br`](https://github.com/Dicklesworthstone/beads_rust) (beads) with `--skip-skills`
4. Installs [`treehouse`](https://github.com/kunchenguid/treehouse) for worktree leasing

**Phase 2 — scaffold**

1. Creates `data/` (registry + memory files with their contracts) if missing
2. Creates `projects/` if missing
3. Runs `br init --prefix cp` if `.beads/` is absent
4. Copies tracked `skills/` into gitignored harness dirs (`.cursor/skills`, `.claude/skills`, `.agents/skills`) so Cursor, Claude Code, and Codex discover them

Put `~/.local/bin` on your `PATH` if it is not already. Re-run anytime; existing
`br` / `treehouse` installs are skipped, muxa is refreshed, scaffold steps are no-ops when already present.

Ask the agent to do work (a GitHub issue URL, or an ad-hoc request). It will
clone the target repo into `projects/<name>` if needed, record it in
`data/projects.md`, track the job with `br`, lease a worktree, and dispatch a
worker.

## Layout

| Path | Tracked? | Role |
|------|----------|------|
| `AGENTS.md`, `CLAUDE.md` | yes | Operating contract |
| `README.md` | yes | This file |
| `bin/install.sh` | yes | Clone-and-go setup (deps + scaffold + skill copies; warns on stale home clones) |
| `bin/cp` | yes | Dispatch precheck (`check`) and runtime jobs map (`jobs`) |
| `test/` | yes | Unit tests for `bin/cp` (`jobs`, occupancy, check, playbook) |
| `reports/` | yes | Design research for this repo |
| `skills/` | yes | Canonical agent skills (`cp-memory`) |
| `data/` | **no** | `data/projects.md`, `data/learnings.md`, `data/candidates.md`, `data/archive.md` |
| `state/` | **no** | Runtime jobs map (`state/jobs.tsv`); row gone at teardown |
| `projects/` | **no** | Cloned repos, one directory per name |
| `.beads/` | **no** | Local `br` state (in-flight jobs + history) |
| `.cursor/skills/`, `.claude/skills/`, `.agents/skills/` | **no** | Harness copies of `skills/` from `bin/install.sh` |

Do not commit `data/`, `state/`, `projects/`, `.beads/`, or harness skill copies.

## What the agent uses

- **GitHub Issues** — the real product backlog, when the caller points at one
- **`br`** — current jobs in this command post, and closed issues as job history
- **`bin/cp jobs`** — runtime-only (worker / worktree / branch, keyed by br id); gone at teardown
- **`data/learnings.md`** — budgeted cross-repo memory (see `AGENTS.md`)

`br` is not a mirror of GitHub. Install runtime tools with `bin/install.sh`.

Worker dispatch also expects `muxa` and `treehouse` on `PATH`. Dispatch and mail
use the **muxa-parent** skill; the job playbook lives in `AGENTS.md`. Before
`muxa dispatch`, run `bin/cp check --project <name> <worktree>` (canonical clone,
git preflight, promote-not-spawn occupancy via `muxa who --json` (`state=idle|busy|ghost`)). Idle worker on a held
worktree → `muxa send` (promote). `muxa dispatch --cwd` warns if that cwd is
already occupied; do not dispatch a duplicate. Bind the leased path to a
variable and pass it — do not retype. `state: dispatched` means the brief is
queued, not received. Lease only from `projects/<name>`;
see [reports/dispatch-hardening.md](reports/dispatch-hardening.md).

## Contract

Read [AGENTS.md](AGENTS.md).
