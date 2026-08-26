# Research job teardown

## Problem

`bin/cp teardown` applied the ship gate (clean + pushed) to every job. Research
workers deliberately push nothing — the brief requires a clean tree and no PR —
so branches cut with `--no-track` at `origin/<default>` never gain an upstream.
Operators hit:

```
[cp] error: unpushed <worktree> branch <id> has no upstream and is not on origin
```

and had to hand-run `treehouse return --force`, `muxa kill`, and `bin/cp jobs done`
after every research job.

## Fix

Teardown reads `kind:research` from the br issue labels (fallback: `--research`
flag). Research jobs require:

1. Clean porcelain (unchanged).
2. No commits on the job branch beyond `origin/<default>`.
3. If `origin/$branch` or `@{u}` exist, tip must still match (accidental push).

Ship jobs (`kind:ship` or unlabeled) still use `assert_clean_and_pushed` unchanged.

## Non-negotiable

A ship job with unpushed commits must still fail closed exactly as before.
`test/teardown.sh` keeps the unpushed-ship cases and adds research paths.
