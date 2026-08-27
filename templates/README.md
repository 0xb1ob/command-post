# Role brief templates

Consumed by `bin/cmdp dispatch --template NAME`. That command substitutes the tokens below before the brief is pasted. Do not invent tokens. Use them verbatim.

## Placeholder contract

| Token | Who substitutes | With |
| --- | --- | --- |
| `{{PARENT}}` | `bin/cmdp dispatch --template` | parent alias (`muxa whoami`) |
| `{{BRANCH}}` | `bin/cmdp dispatch --template` | worktree branch name (receipt token) |
| `{{BR_ID}}` | `bin/cmdp dispatch --template` | br issue id |
| `{{ARTIFACT_PATH}}` | `bin/cmdp dispatch --template` | absolute path outside the worktree for the research artifact |
| `{{TASK}}` | `bin/cmdp dispatch --template` | job body |

`{{ARTIFACT_PATH}}` is outside the worktree so research porcelain stays clean.

`br_id` is also the routing key for Slack thread events: `state/jobs.tsv` maps it to an `origin`, `state/threads.tsv` maps that origin to one thread, and `bin/cmdp relay` renders the event from `thread-events.tsv`. The envelope below is unchanged — the relay reads the ledger, not mail. A job whose row carries no origin is routable nowhere ([contract](../AGENTS.md#slack-threads-origins)).

## Envelope spec

Research worker `muxa send` to the parent is envelope only. Findings body never goes into mail.

```
{{BRANCH}}
status: done|blocked
br_id: {{BR_ID}}
artifact: {{ARTIFACT_PATH}}
summary: <one line>
confidence: high|medium|low
scope: S|M|L
blocking_unknowns: yes|no
destructive_scope: yes|no
suggested_implementer_model: <string>
```

Line 1 is the receipt token (the substituted branch name). Then the fields above.

## When to use

- `brief-ship.md` — orchestrator briefs a `kind:ship` worker that may change code and open a PR.
- `brief-research.md` — orchestrator briefs a `kind:research` worker: artifact to disk, envelope to parent, tree stays clean.
- `gate-rubric.md` — orchestrator briefs a fresh-context reviewer who sees only the research artifact (no repo, no history) before any ship dispatch.
