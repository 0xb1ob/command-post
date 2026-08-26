# Origin-scoped status (#73)

Issue: [command-post#73](https://github.com/0xb1ob/command-post/issues/73)

## Mechanism

`state/jobs.tsv` carries an optional `origin` column stamped at dispatch
(`origin=terminal` for terminal dispatch). Legacy rows without it parse normally
and belong to no origin — no backfill.

`bin/cp status --origin ID` reuses the same assembly path as unscoped status,
then keeps only nodes whose br id maps to that origin in jobs.tsv. When the
scoped view needs dependency state, it also reads `br blocked --limit 0 --json`.

## Cross-origin blocker redaction

If a job in origin A is `br dep`-blocked by a job in origin B, the scoped table
shows phase `blocked` but omits the blocker's br id and title. ids are paired
with plain-language labels by contract; either field would leak B into A's view.

A thread seeing "blocked" with no named reason is intentional until the blocker
shares the same origin or closes.
