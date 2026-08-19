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
- Convention: every issue gets `project:<name>` (matching `projects.md`
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
| Session end | `br sync --flush-only && git add .beads/ && git commit` |
| Restart / new lease | auto-import runs on first command; `br sync --import-only` to force |

### Restart survival

State survives restarts **through git**: the SQLite db is per-worktree and
gitignored, but `issues.jsonl` is committed. A fresh command-post lease gets
the committed JSONL and br rebuilds/refreshes the db on first use. This is
strictly better than the current situation, where backlog state lives in an
uncommitted-until-someone-remembers `backlog.md`. One discipline requirement:
the orchestrator must commit + push `.beads/` at the end of a session, or
state is stranded in the old worktree (same failure mode `backlog.md` already
has). Concurrent leases that both mutate can be reconciled with
`br sync --merge` (`--force-db` / `--force-jsonl` / `--force` newest-wins).

### Comparison with what exists today

| | `backlog.md` | `muxa jobs` | `br` |
|---|---|---|---|
| Storage | markdown in repo | TSV per project in `~/.local/state/muxa/jobs/` | SQLite + JSONL in repo |
| Survives restart | if committed | yes (machine-local) | yes (via git, any machine) |
| Schema | none | fixed: kind, delivery, worker, worktree, branch, status, pr, note | rich: priority, deps, labels, comments, events, defer/due |
| Query | grep | `muxa jobs list` (flat table) | `list/ready/blocked/search/count --json`, dependency-aware |
| Cross-project view | one file | one TSV **per project** — no aggregate view | one db, filter by `project:` label |
| Dependencies between jobs | no | no | yes (`br ready` hides blocked work) |
| Audit trail | git blame | `updated` timestamp | append-only event log + comments |

Observed on this machine: 7 `muxa jobs` TSVs across projects, each a flat
table with no aggregation across them. `backlog.md` in command-post is an
empty template — effectively unused. br fixes both gaps: durable cross-repo
backlog with a single query surface.

**Division of labor with `muxa jobs`:** keep `muxa jobs` as the *runtime
dispatch ledger* (worktree paths, worker aliases, per-spawn mechanics — it's
wired into the orchestrator skill and costs nothing), and make br the *durable
backlog / source of truth* for what work exists, its priority, and its
outcome. Use the br issue ID as the muxa job name (or put it in `note=`) to
link the two. Once br is proven, `muxa jobs` could be dropped, but that's not
required to adopt.

---

## 4. Recommendation: **adopt-with-conventions**

br fits: agent-first (`--json` everywhere), non-invasive (no daemons/hooks/git
surprises), state is git-durable, dependency-aware `ready` is genuinely useful
for sequencing multi-repo work, and the binary is already installed. The
conventions are needed because multi-project support is by-convention (labels),
not first-class.

Caveats: single-maintainer project with a no-contributions policy (mitigated:
frozen architecture, plain-text JSONL escape hatch — worst case we still own a
readable `issues.jsonl`); requires end-of-session commit discipline; adds one
more state surface alongside `muxa jobs` until/unless the latter is retired.

### Exact setup steps for command-post (one-time)

```bash
# in the command-post checkout
export RUST_LOG=error
br init                          # creates .beads/, fixes .gitignore (db ignored, jsonl tracked)
br config set id.prefix=cp       # IDs like cp-<slug>-<hash>
br config set defaults.type=task
```

Then, by hand:

1. Add the label convention and command crib to `AGENTS.md` / `learnings.md`:
   every issue gets `project:<name>` from `projects.md`; optional
   `delivery:pr|local|pipeline`; PR URL goes in the close reason.
   (Skip `br agents --add` — its boilerplate assumes a code repo, not a
   dispatch home.)
2. Replace `backlog.md` body with a pointer: "Backlog lives in `.beads/` —
   query with `br list --json`." Keep the file so existing references don't
   dangle.
3. Commit: `git add .beads/ backlog.md AGENTS.md && git commit -m "Adopt br for backlog"`.

### Orchestrator loop after adoption

```bash
# intake
br create "Fix cluster reads" -p 1 -l project:ssv-ops-dashboard,delivery:pr --slug cluster-reads --json
# dispatch (id from create output)
br update cp-cluster-reads-ab12 --status in_progress --assignee lively-comet
muxa jobs add cluster-reads kind=ship delivery=pr note=cp-cluster-reads-ab12
# completion
br close cp-cluster-reads-ab12 --reason "PR: https://github.com/…/pull/22"
muxa jobs done cluster-reads pr=https://github.com/…/pull/22
# end of session — always
br sync --flush-only && git add .beads/ && git commit -m "backlog sync" && git push
# new lease / restart
br sync --import-only   # or rely on auto-import on first command
```
