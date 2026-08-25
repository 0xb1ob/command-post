---
name: cp-memory
description: >-
  Command-post session-memory curation skill (capture, inspect-then-update,
  decay/archive). Captures, curates, consolidates, and decays session memory
  under data/learnings.md, data/candidates.md, and data/archive.md. Use when
  the user asks to curate, consolidate, or archive memory; at session end;
  every ~10 jobs; or when a worker result yields a machine-local lesson.
---

# cp-memory

Command-post session-memory curation (capture, inspect-then-update,
decay/archive).

Operationalize the Memory contract in `AGENTS.md`. File contracts are created
by `bin/install.sh` when absent. Do not invent a second schema. Do not commit
`data/`.

Run in the command-post **home** checkout (orchestrator / root pane:
`muxa parent` is empty). Do not write `data/` from a leased worktree.

## Fresh-home test (routing)

Before any write to `data/learnings.md`, ask:

> Would a fresh, clean command-post home need this?

| Answer | Destination |
|--------|-------------|
| Yes — general orchestration rule | **AGENTS.md** (rule) + **reports/** (rationale); open a PR |
| Yes — but it is a product defect | Tracked issue (#74–#77, muxa, …); workaround in learnings only until fixed |
| No — this machine's environment only | `data/learnings.md` |
| Not yet sure — needs one more observation | `data/candidates.md` |

Anything that generalizes to all homes is a **contract edit**, not memory.
Job history lives in **br**. Project-intrinsic facts → target repo's `AGENTS.md`
via worker PR.

## When to run

| Trigger | Pass |
|---------|------|
| Worker result or failure, machine-local lesson observed | **Capture** only |
| User asks to curate / consolidate / archive memory | **Curation** |
| Session end | **Curation** |
| ~10 jobs since last curation | **Curation** |

Most jobs yield nothing. Capture is not promotion.

## Files

| File | Role | Write rule |
|------|------|------------|
| `data/learnings.md` | Machine-local residue + interim workarounds | Inspect-then-update; stay small |
| `data/candidates.md` | Observations awaiting routing | Append-only |
| `data/archive.md` | Demoted or absorbed entries | Append with provenance |

Read each file's HTML contract before writing.

Write shapes (from `bin/install.sh`; do not add fields):

```
# candidates.md — one dated line
YYYY-MM-DD <one-line lesson>

# learnings.md — one line each
- YYYY-MM-DD what happened; what to do; evidence: <source>. <!--tier-->

# archive.md — absorbed to contract
- YYYY-MM-DD (from data/learnings.md, <!--…-->, archived YYYY-MM-DD): <entry>. Reason: <why>. Now: AGENTS.md §X / reports/foo.md#anchor
```

Tiers on learnings lines only: `<!--P-->` pinned; `<!--a:DATE-->` aging (≥30d);
`<!--p:DATE-->` perishable (≥7d; must name expiry e.g. issue #N).

## Capture

On a worker's final report, ask whether the lesson is machine-local or an
un-promoted workaround. If it generalizes → **candidate for contract PR**, not
learnings — append to `data/candidates.md` with a note to route to AGENTS.md.

Append one dated line to `data/candidates.md` when:

- Environment-specific (paths, TMUX shell env, local muxa recovery before upstream fix)
- Interim workaround tied to an open issue with a named expiry

Skip: job outcomes, PR URLs, rules every clone needs, project-intrinsic facts.

Do not touch `data/learnings.md` during capture.

## Curation

1. Read `data/learnings.md` and `data/candidates.md` in full.
2. Route generalizable candidates to contract edits (PR) — do not promote them
   into learnings.
3. Classify remaining learnings: duplicate / superseding / obsoleting / archive.
4. Run decay on dated entries.
5. Enforce budget (~60 lines learnings).
6. Write learnings; append archived lines with **Now:** provenance (file + section).
7. Leave `data/candidates.md` append-only except never rewrite/delete lines.

## Consolidation

```bash
wc -l data/learnings.md
```

Over ~60 lines: archive absorbed or stale entries until under. Pinned entries
are not dropped to save space.

## Decay

Lazy at curation only. Perishable ≥7d → check named condition; aging ≥30d
unreinforced → archive. Reinforcement = used this session, not re-reading memory.
Never delete.

## Retrieval

- **Session start:** read `data/learnings.md` (residue should be brief).
- **Pre-dispatch:** AGENTS.md + reports first; `rg -i "<repo>" data/` only if needed.

Do not load `data/archive.md` wholesale. Past jobs: `br list`, `br search`.

## Report

One line per file: `unchanged` / `captured` / `rewritten` / `archived` /
`routed-to-contract`. Counts and any contract PR still needed. No file dumps.

## Do not

- Promote general orchestration rules into learnings (they belong in AGENTS.md)
- Blind-append to learnings or rewrite candidates
- Delete entries
- Commit `data/`
- Edit a target repo's AGENTS.md from the orchestrator pane without dispatch
