# Research: replacing backlog.md with the `br` (beads_rust) issue tracker

Date: 2026-08-19
Scope: evaluate [beads_rust](https://github.com/Dicklesworthstone/beads_rust) as a replacement for `backlog.md` in command-post.
Sources: project README and AGENTS.md (upstream), the `br` CLI itself (v0.2.19, already installed at `/opt/homebrew/bin/br` on this machine), and the current `muxa jobs` state on disk.

---

## 1. What br / beads_rust is

`br` is a Rust port of Steve Yegge's *beads* issue tracker, maintained by Jeffrey
Emanuel (Dicklesworthstone), deliberately frozen at the "classic" **SQLite +
JSONL** architecture. It is a local-first, dependency-aware issue tracker aimed
at AI coding agents. ~1k stars, created Jan 2026, very actively developed
(v0.2.x). License: MIT with an OpenAI/Anthropic rider. The maintainer accepts
**no outside contributions** (bug reports only) — single-maintainer risk, but
the architecture is intentionally frozen, so churn risk is low.

### Install

- Script: `curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/beads_rust/main/install.sh?$(date +%s)" | bash` (installs to `~/.local/bin`, also installs Claude Code / Codex skills unless `--skip-skills`)
- `cargo install --git https://github.com/Dicklesworthstone/beads_rust.git` (needs Rust nightly)
- **Already installed here:** `br 0.2.19` at `/opt/homebrew/bin/br`. No install step needed.
- Optional MCP server (`br serve`, stdio) requires building with `--features mcp`; not needed — the CLI with `--json` is the intended agent interface.

### Data model

`br init` creates a `.beads/` directory in the repo:

| File | Role |
|---|---|
| `beads.db` | SQLite, primary storage, fast queries (gitignored) |
| `issues.jsonl` | one issue per line, **committed to git** — the sync medium |
| `config.yaml` | project config (id prefix, defaults) |
| `routes.jsonl` | optional cross-workspace prefix routes |
| `metadata.json` | workspace metadata |

Issues have: hash-based ID with configurable prefix and optional `--slug`
(e.g. `cp-fix-login-a1b2c3`), title, description, type
(task/bug/feature/epic/question/docs), priority 0–4, status
(open/in_progress/deferred/closed, extensible via `policy.yaml`), assignee,
labels, comments, dependencies (blocking semantics), time estimates, due/defer
dates, and an append-only event audit log. `--ephemeral` issues skip JSONL
export.

Sync is explicit and one-directional per invocation: mutations auto-flush the
JSONL by default; `br sync --import-only` pulls JSONL into SQLite (e.g. after
`git pull`); `br sync --merge` does a three-way merge against a saved base
snapshot when both sides changed. Bare `br sync` is refused by design. br
**never runs git** — commit/push of `.beads/` is your job (non-invasive
philosophy: no daemon, no hooks, no auto-commits).

### How agents drive it

Every command takes `--json`; there are dedicated agent affordances:
`br robot-docs guide`, `br capabilities --format json`, `br schema all`,
attribution env vars (`BR_AGENT_NAME`, `BR_HARNESS`, `BR_MODEL`), and
`br coordination status --json` for diagnosing stale `in_progress` claims.
The canonical agent loop from upstream AGENTS.md:

```bash
br ready --json                          # dependency-aware "what's actionable"
br update <id> --status in_progress --assignee <agent>
# ... do the work ...
br close <id> --reason "Done"            # JSONL auto-flushes
br sync --flush-only                     # idempotent final export check
git add .beads/ && git commit            # explicit git handoff
```

Recommended: `export RUST_LOG=error` to keep output clean for parsing.

---

## 2. Multi-project tracking in a single instance

There is **no first-class "project" field**, but three native mechanisms cover
cross-repo use:

1. **Mixed ID prefixes in one database.** `id.prefix` is only the default for
   *new* issues, not a constraint; one db can hold `cp-…`, `ssv-…`, `api-…`
   IDs side by side. Prefix-per-project is viable but awkward to set per-create
   (prefix comes from config, not a create flag).

2. **Labels with AND/OR filtering.** `br create ... -l project:ssv-ops-dashboard`
   then `br list -l project:ssv-ops-dashboard` (AND) or `--label-any` (OR).
   `br label list-all`, `br count --by status` support triage across the set.
   This is the cleanest single-db namespacing mechanism.

3. **Cross-workspace routing** (`.beads/routes.jsonl`): maps ID prefixes to
   *other* workspaces' `.beads` directories, e.g.
   `{"prefix":"api-","path":"../api"}`. Route-aware commands (`show`, `update`,
   `close`, `dep`, `comments`, …) resolve routed IDs against the target
   workspace, taking its write lock. There is also town-level discovery via a
   parent `mayor/town.json`, and external dependency IDs
   (`external:api:api-123`) so `ready`/`blocked` can account for blockers in
   other workspaces without importing them. Explicitly **not** automatic
   multi-repo sync — each repo still commits its own `.beads/`.

### Best accommodation for command-post

**One db in command-post with a label convention** — not per-project dbs:

- Per-project dbs would require committing `.beads/` into each target repo.
  Several registered projects are shared/external repos (e.g. `stakefish/*`)
  where we can't impose tracker files; and command-post's contract forbids
  treating those repos as its own state anyway.
- Routing/town features solve "issues live in many repos, operate on them from
  one place" — the opposite of our shape, which is "one dispatch home tracks
  jobs *about* many repos."
- Convention: every issue gets `project:<name>` (matching `data/projects.md`
  entries), plus optional `delivery:pr|local|pipeline`. Issue = job; the PR URL
  goes in the close reason or a comment.

---

## 3. Integration with the command-post flow

### Mapping to the orchestrator lifecycle

| Flow point | Command |
|---|---|
| Intake: classify + queue | `br create "<job title>" -t task -p 2 -l project:<repo>,delivery:pr --json` → returns ID |
| Dispatch to worker | `br update <id> --status in_progress --assignee <worker-alias>` |
| Worker blocked | `br comments add <id> "blocker: …"` (issue stays in_progress) |
| Completion | `br close <id> --reason "PR: <url>"` |
| Dropped | `br delete <id>` (tombstone) or `close --reason "dropped: …"` |
| Session end | no git handoff — `.beads/` stays machine-local (see `AGENTS.md`) |
| Restart / new lease | same checkout: `.beads/` persists on disk; new clone: `bin/bootstrap.sh` runs `br init` |

### Restart survival

In command-post, `.beads/` is **local-only and gitignored** — not committed.
State survives restarts on the **same machine** as long as the checkout and
`.beads/` directory remain. A fresh clone gets an empty tracker from
`bin/bootstrap.sh` (`br init --prefix cp`). This is still better than the old
`backlog.md` pattern (uncommitted markdown that was easy to forget): br gives
structured queries and closed-issue history on the machine where work ran.
Upstream br's git-durable JSONL model is documented above for reference;
command-post deliberately does not commit `.beads/`.

### Comparison with what exists today

| | `backlog.md` | `muxa jobs` | `br` |
|---|---|---|---|
| Storage | markdown in repo | TSV per project in `~/.local/state/muxa/jobs/` | SQLite + JSONL in repo |
| Survives restart | if committed | yes (machine-local) | yes (machine-local in command-post; upstream br can commit JSONL) |
| Schema | none | fixed: kind, delivery, worker, worktree, branch, status, pr, note | rich: priority, deps, labels, comments, events, defer/due |
| Query | grep | `muxa jobs list` (flat table) | `list/ready/blocked/search/count --json`, dependency-aware |
| Cross-project view | one file | one TSV **per project** — no aggregate view | one db, filter by `project:` label |
| Dependencies between jobs | no | no | yes (`br ready` hides blocked work) |
| Audit trail | git blame | `updated` timestamp | append-only event log + comments |

Observed on this machine: 7 `muxa jobs` TSVs across projects, each a flat
table with no aggregation across them. `backlog.md` in command-post is an
empty template — effectively unused. br fixes both gaps: durable cross-repo
backlog with a single query surface.

**Division of labor with `muxa jobs`:** keep `muxa jobs` as the *runtime-only
dispatch ledger* (worker alias, worktree path at spawn; cleared at teardown —
no `pr=`, no `note=<br-id>` cross-link). br is the *durable backlog / source
of truth* for what work exists, its priority, status, and outcome (PR URL on
close). Authoritative kind, delivery, and job history live on the br issue;
`muxa jobs` exists only because the CLI requires `kind=` / `delivery=` at
spawn.

---

## 4. Recommendation: **adopt-with-conventions**

br fits: agent-first (`--json` everywhere), non-invasive (no daemons/hooks/git
surprises), state is git-durable, dependency-aware `ready` is genuinely useful
for sequencing multi-repo work, and the binary is already installed. The
conventions are needed because multi-project support is by-convention (labels),
not first-class.

Caveats: single-maintainer project with a no-contributions policy (mitigated:
frozen architecture, plain-text JSONL escape hatch — worst case we still own a
readable `issues.jsonl`); `.beads/` is machine-local (not portable across
clones without export); runtime `muxa jobs` rows are cleared at teardown.

### Exact setup steps for command-post (one-time)

Adopted in this repo — see [`AGENTS.md`](../AGENTS.md) and
[`bin/bootstrap.sh`](../bin/bootstrap.sh):

```bash
# first session in a fresh checkout
bin/bootstrap.sh                 # creates data/, projects/, runs br init --prefix cp if .beads/ absent
export RUST_LOG=error            # optional; keeps br output parseable
```

Then follow the contract in `AGENTS.md`:

1. Register projects in `data/projects.md`; every br issue gets
   `project:<name>` from that registry plus `delivery:pr|local|pipeline`.
2. Track jobs with `br` (`br ready`, `br create`, `br close`, … — all with
   `--json` when parsing output). Do not commit or push `.beads/`.
3. At spawn, record worker + worktree in `muxa jobs` only (runtime ledger;
   no `note=<br-id>`). Put the PR URL on `br close`, not on `muxa jobs done`.

### Orchestrator loop after adoption

```bash
# intake
br create "Fix cluster reads" -t task -p 1 -l project:ssv-ops-dashboard,delivery:pr,kind:ship --slug cluster-reads --json
# dispatch (id from create output)
br update cp-cluster-reads-ab12 --status in_progress --assignee lively-comet --json
muxa jobs add cluster-reads kind=ship delivery=pr worker=lively-comet worktree=<path>
# completion
br close cp-cluster-reads-ab12 --reason "PR: https://github.com/…/pull/22" --json
muxa jobs done cluster-reads
# teardown (parent, from outside the worktree)
treehouse return --force <worktree>
```
