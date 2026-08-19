# Local Long-Term Memory + Self-Learning for command-post

Research report, 2026-08-19. Scope: design a local-only long-term memory and
self-learning loop for command-post (a cross-repo orchestration home whose
current memory is a single plain `learnings.md`). Hard constraint: everything
runs and stores locally — no cloud memory services.

---

## 1. Landscape survey: local memory for AI agents

### 1.1 File-based curated memory

The dominant pattern for coding-agent memory in 2026 is still plain Markdown
files loaded at session start, with the innovation happening in the *contract*
around those files, not the storage.

**firstmate's `learnings.md` + stow skill** ([repo](https://github.com/kunchenguid/firstmate),
[stow SKILL.md](https://github.com/kunchenguid/firstmate/blob/main/skills/stow/SKILL.md))
is the closest prior art to command-post (same shape: an orchestration home
with `backlog.md`, `captain.md`, `projects.md`, `learnings.md`). Its contract:

- `data/learnings.md` holds "fleet-local operational facts and gotchas";
  entries are **dated, evidence-backed, curated**, created lazily.
- Writes are **inspect-then-update, never blind-append**: read the whole file,
  classify the new finding as new / duplicate / superseding / obsoleting,
  then rewrite the affected entry. Duplicates fold in; superseded entries are
  rewritten; the goal is that "every file comes out more accurate, not merely
  longer."
- Entries carry **tier markers** as cheap trailing HTML comments:
  `<!--a:2026-08-03-->` (aging: stale at ≥30 days since last reinforcement),
  `<!--p:2026-07-20-->` (perishable: stale at ≥7 days, must name a checkable
  expiry condition like a ticket or version), `<!--P-->` (pinned: never
  decays). Reinforcement only counts on real evidence — "re-reading memory is
  never reinforcement."
- Stale entries are **archived, never deleted**: they move to a never-loaded
  `.stow-archive.md` with source, tier, date, and a one-line reason. Recovery
  is grep plus copy-back.
- A **startup memory budget** (default ~7,500 estimated tokens across
  `captain.md` + `learnings.md`) caps what every session pays for. Curation
  enforces the budget or surfaces the decision to the user.
- The `/stow` command is the capture trigger: sweep the session for durable
  knowledge (preferences, project facts, gotchas, standing decisions, undone
  next steps), route each finding to its most specific home, and report a
  safe-to-reset verdict. Project-intrinsic knowledge routes to that project's
  committed `AGENTS.md`, not to the home's learnings file — this routing rule
  matters for a cross-repo orchestrator.

**Claude Code memory** ([docs](https://code.claude.com/docs/en/memory)) uses
the same two-layer idea: `CLAUDE.md` is human-authored instructions (keep
under ~200 lines; longer files reduce adherence), and **auto memory**
(`MEMORY.md` in `~/.claude/projects/<hash>/memory/`) is the agent's own
notebook, written autonomously during sessions. Only the first 200 lines /
25KB of MEMORY.md load at startup; the agent is instructed to push detail
into topic files it reads on demand. Community best practice
([orchestrator.dev](https://orchestrator.dev/blog/2026-04-06--claude-code-agent-memory-2026/),
[claudefa.st](https://claudefa.st/blog/guide/mechanics/auto-memory)): rules go
in CLAUDE.md, learned patterns in auto memory, don't duplicate between them,
review periodically because "a bloated MEMORY.md has the same problem as a
bloated CLAUDE.md."

**Skill-based memory**: procedures too long for always-loaded context move
into skills / path-scoped rules that load only when relevant. Claude Code's
docs are explicit: standing facts → CLAUDE.md; multi-step procedures →
skills; path-specific conventions → scoped rules. firstmate's stow may
*propose* (never execute) moving a situational entry into an on-demand home.
This is the cheapest form of retrieval-on-demand: no index, just naming.

### 1.2 Local vector stores

All three mainstream embedded options run fully offline
([comparison 1](https://dreaming.press/posts/sqlite-vec-vs-lancedb-vs-chroma-embedded-vector-store-solo-builder.html),
[comparison 2](https://dreaming.press/posts/sqlite-vec-vs-lancedb-vs-qdrant-agent-memory.html)):

| Store | Model | Sweet spot | Notes |
|---|---|---|---|
| sqlite-vec | SQLite extension, pure C, one `.db` file | up to ~100k vectors, brute-force KNN | Was dormant through 2025; **actively maintained again since v0.1.7 (March 2026, Mozilla-sponsored)**, DiskANN ANN landing in v0.1.10 alphas. Pre-1.0. |
| LanceDB | Embedded Rust, Lance columnar format | larger-than-RAM, ANN (IVF-PQ), dataset versioning ("time travel" = auditable memory) | No server; pre-1.0 but ~11k stars, active. |
| Chroma | Embedded Python/JS, in-memory index + persistence | ≤ ~1M vectors in RAM, nicest API, metadata filtering | Local persistent mode fully offline. |

Embeddings can be produced locally via Ollama (e.g. `nomic-embed-text`, 768
dims) — this is the standard offline stack. The proven hybrid pattern (used by
OpenClaw's memory, [writeup](https://www.pingcap.com/blog/local-first-rag-using-sqlite-ai-agent-memory-openclaw/))
is **one SQLite file with FTS5 (BM25 keyword) + sqlite-vec (semantic), with
graceful fallback to brute-force when the extension is missing**. Important
nuance: SQLite's FTS5 works with zero extensions and no embedding model —
keyword search alone is a big step up from "hope it's in the loaded file."

### 1.3 Memory frameworks (Letta/MemGPT, Mem0, Hindsight)

**Letta (MemGPT)** ([docs](https://docs.letta.com/guides/core-concepts/memory/context-hierarchy/))
defined the canonical tier vocabulary: **core memory** (small editable blocks
pinned in-context, "RAM"), **recall memory** (full conversation history,
queryable), **archival memory** (unlimited out-of-context store, semantic
search via `archival_memory_search`). The agent *self-edits* memory via tools
(`memory_insert`, `memory_replace`, `memory_rethink`). Runs self-hosted
(Docker, Postgres/SQLite state), Apache 2.0, but it is a **full agent
runtime** — your agents run *inside* Letta. Also promotes MemFS (memory
blocks projected as a git-tracked filesystem) and sleep-time
consolidation ("dreaming"). Adopting it would replace command-post's
architecture, not extend it.

**Mem0** ([repo](https://github.com/mem0ai/mem0), Apache 2.0) is a bolt-on
memory library: LLM extracts facts from conversations at write time,
stores them in a vector store, retrieves per-query. **Fully offline is
supported but not default**: you must configure Ollama for LLM + embedder and
a local Qdrant/Chroma vector store via `Memory.from_config` (defaults are
OpenAI + local Qdrant at `/tmp/qdrant`, history in `~/.mem0/history.db`).
Self-hosted server ships via Docker Compose. Real-world local setups work but
report configuration sharp edges (embedding dims must be pinned before first
write).

**Hindsight** ([vectorize](https://vectorize.io/articles/hindsight-vs-letta),
MIT, ~4k stars) is a standalone local memory layer: passive extraction,
unified store, four parallel retrieval strategies (semantic + keyword +
graph + temporal) with reranking; 94.6% on LongMemEval. One Docker command,
self-hostable. Worth watching, but a service dependency.

### 1.4 Knowledge-graph approaches

**Graphiti** ([repo](https://github.com/getzep/graphiti), Apache 2.0, ~27k
stars, the engine behind Zep) builds **bi-temporal knowledge graphs**: every
fact edge records when it was true in the world (`valid_at`/`invalid_at`) and
when the system learned it (`created_at`/`expired_at`), so it can answer
"what was true before X." Incremental LLM extraction per episode, entity
resolution, contradiction handling; retrieval is cosine + BM25 + graph
traversal. Runs locally against Neo4j/FalkorDB/Kuzu with Ollama-compatible
endpoints, often exposed over MCP.

**Cognee** treats memory as a data pipeline (`add()` → `cognify()` →
`search()`), writing to graph + vector + relational stores together; defaults
are embedded (Kuzu-based graph, LanceDB vectors) so it runs locally, with an
agent facade of `remember/recall/forget/improve` and audit/provenance
emphasis.

Verdict for command-post: temporal KGs solve "facts about entities that
change over time" (customer addresses, org charts). Orchestrator learnings
are mostly *procedural gotchas* ("repo X's CI needs Y"), which a dated
Markdown entry represents fine. The KG machinery (graph DB + LLM extraction
pipeline) is disproportionate here.

### 1.5 Field consensus

The 2026 convergent architecture across all these systems
([survey](https://noscomelaia.com/memoria-de-agentes-lo-que-el-campo-decidio-y-lo-que-nadie-resuelve/),
[Hindsight consolidation post](https://hindsight.vectorize.io/blog/2026/05/21/agent-memory-consolidation)):

1. **Three tiers**: working context ("RAM") / small curated core, always
   loaded and human-readable / large archival store, retrieved on demand.
2. **Two async processes**: extraction at write time (consolidate facts, not
   raw transcripts) and periodic background consolidation/curation.
3. **Write-time consolidation beats read-time cleverness**: extract atomic
   facts, deduplicate and resolve conflicts when writing, so retrieval stays
   simple.

Plain `learnings.md` already *is* the curated core tier. What it lacks is the
capture trigger, the evidence/archive tier, and the decay policy.

---

## 2. The self-learning loop

### 2.1 Capture: how learnings should be produced

**Post-job reflection (Reflexion pattern)**
([Shinn et al. 2023](https://arxiv.org/abs/2303.11366)): convert outcome
signals into verbal lessons stored in episodic memory and replayed as context
on future attempts. The production lesson
([build log](https://niteagent.com/blog/build-log-agent-self-reflection-loop/),
[Developers Digest](https://www.developersdigest.tech/blog/self-improving-agents-in-5-minutes)):
reflection must be **grounded in external signals** (test results, CI status,
worker blockers) or you get confident noise; and reflections must **persist
across sessions** — an in-memory buffer means the same mistake recurs next
session.

**Accumulated behavioral rules**
([arXiv 2607.13091](https://arxiv.org/html/2607.13091v1)): every accepted
correction is codified as a persistent rule in a **version-controlled
instruction file**, checked by a pre-submission self-review checklist. In
production the rule set grew 5 → 18 rules with a measured **0% recurrence
rate for ruled-against error classes**. Key insight for command-post:
Reflexion works *within* an episode; durable rule files are what cross the
session boundary. Both are text files — no infrastructure.

**Capture triggers that exist in the wild:**

- *Session-end sweep* (firstmate `/stow`): re-read the session, extract
  durable findings, route each to its most specific home, report what's now
  safe to forget. Weakness: relies on the sweep actually running.
- *Continuous auto memory* (Claude Code): the agent writes MEMORY.md
  mid-session when it learns something durable. Weakness: noisy without
  stewardship; docs recommend explicit saves for critical knowledge.
- *Event-driven hooks*: capture on failure events (a worker reports a
  blocker, CI goes red twice for the same cause). Highest signal per entry —
  failures and surprises are where learnings live.

**What fits an orchestrator**: command-post has a natural event loop — every
job ends with a worker result (done / blocker / PR). That result message is
exactly the grounded external signal Reflexion needs. The capture point
should be **the moment the orchestrator processes a worker's final report**,
plus a post-mortem when a job fails or a lease is left dirty. Decision logs
("chose repo X over Y because…") are a third, cheaper stream: append at
dispatch time, no reflection needed.

### 2.2 Retrieval: getting learnings back at the right time

Two retrieval moments matter for an orchestrator, and existing systems cover
both:

- **Session-start digest**: the curated core loads automatically (Claude Code
  loads CLAUDE.md + first 200 lines of MEMORY.md; firstmate prints
  `learnings.md` in its session-start context digest, inside the startup
  budget). This is push-based and only works if the file is small — hence
  budgets.
- **Pre-dispatch lookup**: before spawning a worker into repo X, query memory
  for entries about repo X (Letta's `archival_memory_search`; Mem0's
  per-query retrieval; OpenClaw's hybrid FTS5+vector search; or a plain
  grep). This is pull-based and is where the archival tier earns its keep —
  the "5–10 relevant memories per task, never the full history" rule
  ([operating guide](https://fountaincity.tech/resources/blog/how-to-build-and-operate-ai-agent-memory-in-2026/)).

A third pattern worth stealing: **inject relevant learnings into the worker's
brief**, not just the orchestrator's context. The orchestrator is the only
place cross-repo lessons accumulate; workers are ephemeral. A pre-dispatch
lookup that pastes two relevant gotchas into the job brief closes the loop.

---

## 3. Curation and decay: keeping memory from rotting

Stale memory is worse than no memory — it actively degrades decisions
([2026 operating guide](https://fountaincity.tech/resources/blog/how-to-build-and-operate-ai-agent-memory-in-2026/)).
Strategies in maturity order:

- **Dated entries** (floor requirement): every entry carries its
  last-reinforced date. Undated memory can't be aged. firstmate's compact
  markers (`<!--a:2026-08-03-->`) cost a few bytes and make the clock
  machine-checkable.
- **Tier clocks**: pinned (never decays) / aging (stale at 30 days,
  re-validate or archive) / perishable (stale at 7 days, must name a
  checkable expiry condition — a ticket, a version, a dated expectation).
  Reinforcement requires real evidence of use this session.
- **Startup budgets**: a hard token/line allowance for always-loaded files
  (firstmate: ~7,500 tokens across its memory surface; Claude Code: 200
  lines). Budget pressure is what forces curation to actually happen.
- **Archive, don't delete**: stale entries move to a never-loaded archive
  file with provenance (source, tier, date, reason). Recovery is grep.
  Research agrees hard deletion should be reserved for compliance;
  performance problems are solved by consolidation and demotion, not
  eviction ([Hindsight](https://hindsight.vectorize.io/blog/2026/05/21/agent-memory-consolidation)).
- **Rewrite-over-append / consolidation**: fold duplicates, rewrite
  superseded entries in place. Academic systems dress this up
  (MemArchitect's FSRS forgetting curves and entropy-triggered consolidation,
  [arXiv 2603.18330](https://arxiv.org/pdf/2603.18330); DMF's deterministic
  CPU-only survival scores, [arXiv 2606.03463](https://arxiv.org/html/2606.03463v1);
  Oblivion's decay-driven activation, [arXiv 2604.00131](https://arxiv.org/pdf/2604.00131)),
  but the operational core is identical: score by recency × utility ×
  frequency, demote under budget pressure, archive rather than delete.
- **Decay evaluated at curation time, not on a daemon**: firstmate's clocks
  only tick when `/stow` runs. For a system without background processes
  (command-post), lazy evaluation at each curation pass is the honest design.

---

## 4. Recommendation for command-post

> **Implemented contract:** This section is a research proposal. What shipped in
> this repo is in [`AGENTS.md`](../AGENTS.md) and [`bin/bootstrap.sh`](../bin/bootstrap.sh):
> memory under `data/` (`learnings.md`, `candidates.md`, `archive.md`), project
> registry in `data/projects.md`, and job history in local-only `br` (`.beads/`,
> not committed). The layout below was not adopted as written.

### 4.1 Design principle

Stay file-based and boring. Command-post's learnings volume (one orchestrator,
tens of jobs per month) is decades away from where grep stops working — the
OpenClaw/flexvec-style SQLite machinery pays off at tens of thousands of
chunks, not tens of entries. What plain `learnings.md` actually lacks is not
search, it's **(a) a reliable capture trigger, (b) an evidence trail, (c) a
decay policy, and (d) a pre-dispatch lookup**. All four are contract + one
new directory, zero dependencies. Everything stays inspectable in a text
editor and versioned in git.

### 4.2 File layout

```
learnings.md            # curated core — always loaded, budgeted (exists today)
memory/
  jobs.md               # append-only job journal: one dated block per job
  decisions.md          # append-only dispatch-decision log (one line each)
  archive.md            # cold tier — never loaded; stale entries with provenance
projects.md             # per-project standing notes stay here (exists today)
```

- **`learnings.md`** keeps its role but gains the firstmate contract:
  entries are dated with tier markers (`<!--P-->` pinned, `<!--a:DATE-->`
  aging/30d, `<!--p:DATE-->` perishable/7d + named expiry condition), one
  line each, evidence-backed ("what happened, what to do, which job proved
  it"). Budget: **max ~60 lines / ~1,500 tokens**. Updated only via
  inspect-then-update — read whole file, fold or supersede, never blind
  append.
- **`memory/jobs.md`** is the recall/evidence tier. After every job the
  orchestrator appends a short block: date, job id, target repo, outcome
  (done/blocker/failed), PR link, and 0–3 candidate learnings. Append-only,
  never loaded wholesale, greppable. This is what makes learnings
  *evidence-backed*: each learning cites the job block that produced it.
- **`memory/decisions.md`**: one line per dispatch ("2026-08-19 routed job X
  to repo Y because Z"). Cheap to write, invaluable in post-mortems
  ("why did we keep sending auth work to repo A?").
- **`memory/archive.md`**: stale learnings move here with source, tier,
  date, and one-line reason. Never loaded; recovery is `rg` plus copy-back.

Routing rule (adopted from firstmate): knowledge intrinsic to one project —
"repo X's tests need flag Y" — does **not** live in command-post; a worker
delivers it into that repo's `AGENTS.md` via normal PR. `learnings.md` holds
only cross-repo/orchestration knowledge ("workers on repo X need bigger
timeout leases", "never dispatch two workers into the same repo's main
worktree").

### 4.3 Capture workflow (the self-learning loop)

Wire capture into the three moments the orchestrator already touches, as
short additions to AGENTS.md (or a small skill):

1. **At dispatch**: append one decision line to `memory/decisions.md`.
2. **On worker result** (the grounded signal): append the job block to
   `memory/jobs.md`, answering three reflection prompts — *what failed or
   surprised, what would be done differently, what should the next dispatch
   to this repo know*. Most jobs yield zero candidates; that's fine.
3. **On failure/blocker**: mandatory post-mortem in the job block — root
   cause in one sentence, plus a candidate learning. Failures are where the
   0%-recurrence payoff lives ([accumulated-rules result](https://arxiv.org/html/2607.13091v1)).

**Promotion is separate from capture.** Candidates sit in `memory/jobs.md`
until a curation pass (end of session, or whenever `learnings.md` is
touched) promotes the ones that generalize into `learnings.md` via
inspect-then-update. This two-stage design keeps the core file curated while
never losing a raw observation — the same split every surveyed system
converged on (extraction at write time, consolidation later).

### 4.4 Retrieval workflow

1. **Session start**: read `learnings.md` in full (it's budgeted, so this is
   cheap). Command-post's AGENTS.md already implies this; make it explicit.
2. **Pre-dispatch lookup**: before spawning into repo X, run
   `rg -i "<repo-name>" learnings.md memory/` and paste at most 2–3 relevant
   hits **into the worker's brief**. Deterministic, sub-second, zero infra.
3. **Post-mortems**: grep `memory/jobs.md` + `memory/decisions.md` by repo or
   date range.

### 4.5 Curation cadence

At each session end (or every ~10 jobs, whichever comes first):

- Evaluate tier clocks: perishable ≥7d → check its named condition, refresh
  or archive; aging ≥30d without reinforcement this period → archive with
  reason. Reinforce only entries actually used this session.
- Enforce the budget: over 60 lines → consolidate or demote until under.
- Promote job-log candidates that have recurred or clearly generalize.

Lazy evaluation only — no daemon, nothing happens between passes.

### 4.6 What was considered and rejected (for now)

- **Local vector store (sqlite-vec/LanceDB/Chroma + Ollama embeddings)**:
  fully viable offline and sqlite-vec is actively maintained again, but at
  command-post's scale semantic search adds an embedding model dependency to
  solve a problem grep doesn't have yet. Revisit if `memory/` exceeds a few
  thousand entries or pre-dispatch grep visibly misses relevant learnings.
  The upgrade path is clean: index `memory/*.md` into one SQLite file with
  FTS5 first (still zero ML), sqlite-vec second (OpenClaw pattern).
- **Mem0 / Letta / Hindsight**: all self-hostable, but each adds a service
  (Docker, Qdrant/Postgres) and an LLM extraction pipeline to do what a
  disciplined Markdown contract does at this scale — and their store is less
  inspectable than files in git.
- **Knowledge graphs (Graphiti/Cognee)**: bi-temporal graphs answer
  "what changed when" about entity-rich domains; orchestration gotchas are
  procedural one-liners. Wrong tool here.

### 4.7 Why this beats plain `learnings.md`

| Gap in the status quo | Fix |
|---|---|
| Capture depends on remembering to write | Wired to dispatch/result/failure events the orchestrator already handles |
| No evidence trail | Every learning cites its job block in `memory/jobs.md` |
| Entries rot silently | Dated tier markers + lazy decay clocks + archive-not-delete |
| File grows unboundedly or gets purged ad hoc | Hard budget (~60 lines) forces consolidation; archive preserves everything |
| Learnings never reach workers | Pre-dispatch grep pastes relevant hits into the brief |
| No memory of *decisions*, only conclusions | `memory/decisions.md` one-liners |

Total cost: one new directory, three Markdown files, and a ~30-line contract
addition to AGENTS.md. Fully offline, git-versioned, greppable, and every
byte human-auditable.

---

## Sources

- firstmate: [AGENTS.md](https://github.com/kunchenguid/firstmate/blob/main/AGENTS.md) · [configuration](https://github.com/kunchenguid/firstmate/blob/main/docs/configuration.md) · [architecture](https://github.com/kunchenguid/firstmate/blob/main/docs/architecture.md) · [public stow skill](https://github.com/kunchenguid/firstmate/blob/main/skills/stow/SKILL.md)
- Claude Code memory: [official docs](https://code.claude.com/docs/en/memory) · [2026 best practices](https://orchestrator.dev/blog/2026-04-06--claude-code-agent-memory-2026/) · [auto-memory mechanics](https://claudefa.st/blog/guide/mechanics/auto-memory)
- Local vector stores: [sqlite-vec vs LanceDB vs Chroma](https://dreaming.press/posts/sqlite-vec-vs-lancedb-vs-chroma-embedded-vector-store-solo-builder.html) · [agent-memory comparison](https://dreaming.press/posts/sqlite-vec-vs-lancedb-vs-qdrant-agent-memory.html) · [sqlite-vec v0.1.7 revival](https://github.com/asg017/sqlite-vec/releases/tag/v0.1.7) · [OpenClaw SQLite memory](https://www.pingcap.com/blog/local-first-rag-using-sqlite-ai-agent-memory-openclaw/) · [flexvec](https://arxiv.org/html/2603.22587v1)
- Frameworks: [Letta context hierarchy](https://docs.letta.com/guides/core-concepts/memory/context-hierarchy/) · [Letta archival memory](https://docs.letta.com/guides/core-concepts/memory/archival-memory/) · [mem0](https://github.com/mem0ai/mem0) · [mem0 fully-local setup](https://loze.hashnode.dev/fixing-mem0-local-ollama-and-openclaw-mem0-with-qdrant-ollama-locally) · [Hindsight vs Letta](https://vectorize.io/articles/hindsight-vs-letta)
- Knowledge graphs: [Graphiti](https://github.com/getzep/graphiti) · [Letta/Mem0/Graphiti/Cognee compared](https://codepointer.substack.com/p/agent-memory-systems-and-knowledge)
- Self-learning: [Reflexion (Shinn et al.)](https://arxiv.org/abs/2303.11366) · [Reflexion in production](https://niteagent.com/blog/build-log-agent-self-reflection-loop/) · [Accumulated behavioral rules](https://arxiv.org/html/2607.13091v1) · [self-improving agent patterns](https://www.developersdigest.tech/blog/self-improving-agents-in-5-minutes)
- Curation/decay: [Hindsight on consolidation](https://hindsight.vectorize.io/blog/2026/05/21/agent-memory-consolidation) · [operating agent memory in 2026](https://fountaincity.tech/resources/blog/how-to-build-and-operate-ai-agent-memory-in-2026/) · [MemArchitect](https://arxiv.org/pdf/2603.18330) · [DMF](https://arxiv.org/html/2606.03463v1) · [Oblivion](https://arxiv.org/pdf/2604.00131) · [field synthesis](https://noscomelaia.com/memoria-de-agentes-lo-que-el-campo-decidio-y-lo-que-nadie-resuelve/)
