# Dispatch hardening: treehouse leases and worker promotion

Date: 2026-08-19
Issue: [command-post#6](https://github.com/0xb1ob/command-post/issues/6)
Contract: [AGENTS.md](../AGENTS.md) Pre-dispatch

Two orchestrator mistakes from the first multi-repo dispatch session. Both were
already forbidden in spirit; this note is the fail-closed recovery so they are
not repeated. Promotion and treehouse lease recovery stay in command-post.
Occupied-cwd warning belongs in `muxa spawn --cwd`. `bin/cp check` fail-closes
that policy (reads `muxa who`, promote-not-spawn) plus clone/worktree facts.
Do not reimplement `muxa spawn`.

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
  → no muxa spawn, no new treehouse lease

worktree returned, or job is independent (other repo / second worktree)
  → treehouse get --lease from projects/<name>
  → muxa spawn --cwd <worktree>
```

Before spawn: `bin/cp check --project <name> <worktree>` (and `muxa who` CWD
column). `muxa spawn --cwd` warns if a registered worker already occupies
that path — promote with `muxa send`, do not spawn a second pane. Ghost
panes: `muxa unregister`, do not promote.

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

## Orchestration notes

- Before `muxa spawn`, run `bin/cp check --project <name> <worktree>`.
  Promote with `muxa send` instead of duplicate spawn. Occupied cwd is
  muxa's warning on `muxa spawn --cwd`; the checker applies promote-not-spawn
  from `muxa who` and does not reimplement spawn.
- Treehouse preflight "belongs to another repo" → return the lease and fix
  the canonical `projects/<name>` clone; do not fall back without fixing
  registration.
- `muxa jobs` is runtime-only (worker + worktree); br holds kind / delivery /
  status / PR. Do not cross-link via `note=<br-id>`.
- Parallel `muxa spawn` can race and assign the same alias; spawn sequentially
  or pass `--name` so send targets stay unique.
