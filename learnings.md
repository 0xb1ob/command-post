# Learnings

<!-- Operational knowledge that survives across sessions. Curate and prune. -->

## br backlog (2026-08-19)

- Durable queue is `br` in `.beads/`, not `backlog.md`. `muxa jobs` stays as the in-flight dispatch ledger; put the br issue id in `note=`.
- Labels: `project:<name>` must match `projects.md`; `delivery:pr|local|pipeline` matches the job. Close with `PR: <url>` in `--reason`.
- End of session: `br sync --flush-only && git add .beads/ && git commit && git push`. A fresh lease rebuilds SQLite from committed `issues.jsonl`.
