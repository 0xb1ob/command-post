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

### Why receipt is kind-aware (command-post-6wco)

The branch-token check above is a Cursor-shaped check, and only works for
Cursor. Applying it to `kind=claude` panes fails in both directions at once,
which is how a real silent dispatch failure went unnoticed for a stretch of
live jobs before it was caught:

- **False positive.** `bin/cp dispatch` sets `branch=br-id` and creates that
  branch on the leased worktree *before* the pane is even spawned. A claude
  pane's footer renders `<cwd> (<branch>) | <model> | Context: N%` regardless
  of whether anything was ever pasted into it. Grepping the tail for the bare
  branch name therefore matches the footer on a pane that received nothing —
  five dispatches self-reported `receipt=confirmed` this way while two of
  them had received nothing at all.
- **False negative.** Claude consumes a pasted brief into its conversation
  instead of echoing it back into the visible pane, so the strict
  `Branch: ${branch}` token never appears even on a pane that is actively
  working the job. Scoring that as `receipt=unconfirmed` forever is
  indistinguishable from genuine non-delivery.

The reliable signal for `kind=claude` is the footer's own `Context: N%`: an
empty prompt reads `Context: 0.0%`, and any pasted, tokenized content pushes
it above zero. `bin/cp dispatch` reads kind from `muxa who --json` (never
from the agent CMD or from pane text) and branches the check accordingly —
see `worker_kind` and the receipt block in `cmd_dispatch` (`bin/cp`).

**Timing caveat, learned from a real false alarm:** the broker deliberately
waits for the CLI to boot, draw, and go quiet before pasting, and claude's
own boot is slow enough to *look* identical to a dropped paste — an
instantaneous `Context: 0.0%` reading taken the moment a pane appears is not
evidence of anything. A prior investigation wrongly declared the delivery bug
reproduced off exactly this kind of instant reading. To make that
misdiagnosis structurally impossible, a zero/absent `Context: N%` reading for
a claude pane is reported as `receipt=unknown`, never `receipt=unconfirmed`
and never treated as not-received: one single, non-looping tail check simply
cannot distinguish "still booting" from "genuinely dropped," so the verdict
says so explicitly instead of guessing. The remedy is the same as
`unconfirmed` — wait for `[muxa]` mail, never re-dispatch, never re-paste.

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
