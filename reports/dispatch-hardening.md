# Dispatch hardening: treehouse leases and worker promotion

Date: 2026-08-19
Issue: [command-post#6](https://github.com/0xb1ob/command-post/issues/6)
Contract: [AGENTS.md](../AGENTS.md) Pre-dispatch

Supersession (2026-08-21, [#15](https://github.com/0xb1ob/command-post/issues/15)):
the spawn-then-brief sequence is `muxa dispatch`. Occupied-cwd warning is
`muxa dispatch --cwd` (same as `muxa spawn --cwd`). Do not reimplement
dispatch. Exit 0 / `state: dispatched` means queued, not received.

Two orchestrator mistakes from the first multi-repo dispatch session. Both were
already forbidden in spirit; this note is the fail-closed recovery so they are
not repeated. Promotion and treehouse lease recovery stay in command-post.
Occupied-cwd warning belongs in `muxa dispatch --cwd`. `bin/cp check` fail-closes
that policy (reads `muxa who --json`, promote-not-spawn) plus clone/worktree
facts. Do not reimplement `muxa dispatch`.

## 1. Duplicate spawn instead of promotion

Worker `silver-sparrow` finished [PR #5](https://github.com/0xb1ob/command-post/pull/5)
and stayed idle on the leased worktree. A follow-up job spawned `quiet-fox` on
the **same cwd** instead of rebriefing `silver-sparrow`.

Impact: two panes on one worktree; clutter; concurrent-edit risk if both were
active.

### Decision tree

```
same repo + same worktree still held (lease not returned)
  → muxa send <alias>  (promote)
  → no muxa dispatch, no new treehouse lease

worktree returned, or job is independent (other repo / second worktree)
  → treehouse get --lease from projects/<name>
  → bind the printed path; muxa dispatch --cwd "$worktree"
```

Before dispatch: `bin/cp check --project <name> "$worktree"` (and `muxa who --json`
`cwd`). `muxa dispatch --cwd` warns if a registered worker already occupies
that path — promote with `muxa send`, do not dispatch a second pane. Ghost
panes: `muxa kill NAME|ID` (dead pane) or restart the CLI in that pane; do
not promote.

## 2. Stale clone / "belongs to another repo"

`treehouse get --lease` for command-post returned a worktree linked to
`~/command-post/.git`, not `projects/command-post/.git`. Preflight failed.
The orchestrator fell back to `git worktree add projects/.worktrees/…` —
outside the treehouse pool.

Impact: manual `git worktree remove` instead of `treehouse return`; pool stays
mis-pointed.

### Recovery (do not fall back)

1. `treehouse return --force <bad-worktree>`
2. Fix registration: `data/projects.md` Path = `projects/<name>`; retire or
   rename extra clones (`~/command-post`, …) so they are not lease cwd
3. Re-lease from the canonical clone (`treehouse get --lease` with cwd
   `projects/<name>`)
4. `bin/cp check --project <name> <worktree>` on the new path

`git worktree add` only when treehouse is **not installed**. A wrong-repo
preflight is not "treehouse unavailable."

`bin/install.sh` warns when `$HOME/<name>` is a different git repo from
`projects/<name>` (or this checkout vs `~/command-post`).

### Why not `git worktree add`

`treehouse get --lease` keys off the git repo of the cwd you run it from. A
leftover clone (e.g. `~/command-post`) yields a worktree linked to that `.git`,
not `projects/<name>/.git`. `bin/cp check` then fails: the path **belongs to
another repo**.

Recovering with `git worktree add` under `projects/.worktrees/` (or anywhere)
bypasses the treehouse pool. Teardown becomes `git worktree remove` instead of
`treehouse return`, and the pool stays wrong. That is why the contract allows
`git worktree add` only when treehouse is **not installed**, and treats a
treehouse failure as still-installed.

## First-brief receipt

Cursor Agent can collapse a paste to a placeholder and scroll it away, so the
broker's confirm-before-done may log a successful delivery as unconfirmed and
re-paste when the pane next looks free. Until that muxa bug lands, verify
receipt independently: unique token in every first brief (the worktree's branch
name), confirm with one `muxa tail NAME` that the token appeared. Do not loop
tail. Token absent and no `[muxa] from=broker` yet → wait for mail; do not
re-dispatch.

## Teardown

Plain `treehouse return` (no `--force`) prompts interactively. `--force` resets
without asking — which is why the worker's clean-and-pushed gate runs first,
and why the parent (not the worker) is the actor: `treehouse return --force`
from outside the worktree, then `muxa kill NAME|ID`.

## Orchestration notes

- Before `muxa dispatch`, run `bin/cp check --project <name> "$worktree"`.
  Promote with `muxa send` instead of a second dispatch. Occupied cwd is
  muxa's warning on `muxa dispatch --cwd`; the checker applies promote-not-spawn
  from `muxa who --json` and does not reimplement dispatch.
- Bind the leased path to a variable and pass it; do not retype.
- `state: dispatched` means queued, not received. Confirm the brief token
  with one `muxa tail NAME`.
- Treehouse preflight "belongs to another repo" → return the lease and fix
  the canonical `projects/<name>` clone; do not fall back without fixing
  registration.
- `bin/cp jobs` is runtime-only (worker + worktree + branch, keyed by br id);
  br holds kind / delivery / status / PR. Do not store those on the runtime map.
- Parallel `muxa dispatch` can race and assign the same alias; dispatch sequentially
  or pass `--name` so send targets stay unique.
