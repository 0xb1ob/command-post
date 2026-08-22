# Role brief templates

Consumed by `bin/cp dispatch --template NAME`. That command substitutes the tokens below before the brief is pasted. Do not invent tokens. Use them verbatim.

## Placeholder contract

| Token | Who substitutes | With |
| --- | --- | --- |
| `{{PARENT}}` | `bin/cp dispatch --template` | parent alias (`muxa whoami`) |
| `{{BRANCH}}` | `bin/cp dispatch --template` | worktree branch name (receipt token) |
| `{{BR_ID}}` | `bin/cp dispatch --template` | br issue id |
| `{{ARTIFACT_PATH}}` | `bin/cp dispatch --template` | absolute path outside the worktree for the research artifact |
| `{{TASK}}` | `bin/cp dispatch --template` | job body |

`{{ARTIFACT_PATH}}` is outside the worktree so research porcelain stays clean.

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
