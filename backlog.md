# Backlog

The durable backlog lives in `.beads/` (`br` / beads_rust). This file is a pointer, not a second queue.

- Dispatchable work: `br ready --json`
- Full list: `br list --json`
- Intake: `br create "<title>" -t task -p 2 -l project:<name>,delivery:pr --json`

Labels, close-with-PR-URL, muxa-jobs linking, and the end-of-session flush are in [AGENTS.md](AGENTS.md).
