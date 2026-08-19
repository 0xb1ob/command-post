---
name: cp-memory
description: >-
  Command-post session-memory curation skill (capture, inspect-then-update,
  decay/archive). Captures, curates, consolidates, and decays session memory
  under data/learnings.md, data/candidates.md, and data/archive.md. Use when
  the user asks to curate, consolidate, or archive memory; at session end;
  when data/learnings.md is touched; every ~10 jobs; or when a worker result
  or failure yields a lesson.
---

# cp-memory

Command-post session-memory curation (capture, inspect-then-update,
decay/archive).

Operationalize the Memory contract in `AGENTS.md`. File
contracts (header + format) are created by `bin/install.sh` when the files are
absent. Do not invent a second schema. Do not commit `data/`.

Run this in the command-post **home** checkout (orchestrator / root pane:
`muxa parent` is empty). Do not write `data/` from a leased worktree.

## When to run

| Trigger | Pass |
|---------|------|
| Worker result or failure, and a lesson was observed | **Capture** only |
| User asks to curate / consolidate / archive memory | **Curation** (includes decay + budget) |
| Session end | **Curation** |
| `data/learnings.md` is about to be touched | **Curation** before/as you write |
| ~10 jobs since the last curation this session | **Curation** |

Most jobs yield nothing. Capture is not promotion.

## Files

| File | Role | Write rule |
|------|------|------------|
| `data/learnings.md` | Curated core; always loaded; ~60 lines / ~1,500 tokens | Inspect-then-update only |
| `data/candidates.md` | Reflection candidates; never loaded wholesale | Append-only |
| `data/archive.md` | Cold tier; never loaded at session start | Append stale entries with provenance |

Read the HTML contract in each file before writing. Job history lives in **br**
(closed issues + comments), not here.

Write shapes (from `bin/install.sh`; do not add fields):

```
# candidates.md — one dated line; failures/blockers include a one-sentence root cause
YYYY-MM-DD <one-line lesson>

# learnings.md — one line each
- YYYY-MM-DD what happened; what to do; evidence: <source>. <!--tier-->

# archive.md
- YYYY-MM-DD (from data/learnings.md, <!--a:…-->, archived YYYY-MM-DD): <entry>. Reason: <why>
```

Tiers (trailing HTML comments on learnings lines only):

- `<!--P-->` pinned — never decays
- `<!--a:YYYY-MM-DD-->` aging — stale at ≥30 days since last reinforcement
- `<!--p:YYYY-MM-DD-->` perishable — stale at ≥7 days; the line must name a checkable expiry (ticket, version, dated expectation)

Default new entries to aging. Use pinned only for standing orchestration rules.
Use perishable only when a checkable condition is in the text. An entry that
cannot name one is aging, not perishable.

## Capture

On a worker's final report (done / blocker / failed), ask:

1. What failed or surprised?
2. What would we do differently next time?
3. What should the next dispatch to this repo know?

If the answer is a **cross-repo / orchestration** lesson that could recur,
append **one** dated line to `data/candidates.md`. Skip otherwise.

Failures and blockers: capture when a generalization is worth promoting;
include the root cause in that one line. One-off blips: skip.

Do not capture:

- Job outcomes, PR URLs, or chronology — those belong in br
- Project-intrinsic facts ("repo X's tests need flag Y") — those go to that
  repo's `AGENTS.md` via a worker PR (report the need; do not spawn unasked)
- Preferences that belong in `captain.md`

Do not rewrite or delete candidate lines. Do not touch `data/learnings.md`
during capture.

```
2026-08-19 Two workers on the same clone primary checkout tangled branches; lease one worktree per worker.
2026-08-19 Blocker: treehouse return from inside the worktree killed the worker shell (root cause: return terminates the process tree). Teardown from outside only.
```

## Curation

Inspect-then-update. Never blind-append to `data/learnings.md`. Every write
leaves that file more accurate, not merely longer.

1. Read `data/learnings.md` in full. Do not write yet.
2. Read `data/candidates.md`.
3. Classify each unpromoted candidate against current learnings:

   | Class | Action |
   |-------|--------|
   | Not general / noise | Skip. Leave the candidate line. |
   | Job history | Skip. It belongs in br. |
   | Project-intrinsic | Skip. Report that it needs a worker PR to that repo's `AGENTS.md`. |
   | Duplicate | Fold any new evidence into the existing line. Prefer one sentence over a second entry. |
   | Superseding | Rewrite the existing line in place. |
   | Obsoleting | Archive the old line, then write the new truth. |
   | New and in scope | Add one dated learnings line with a tier marker and `evidence:`. |

4. Run [Decay](#decay) on every dated learnings entry.
5. Enforce the budget ([Consolidation](#consolidation)).
6. Write the considered `data/learnings.md`. Rewrite affected entries; do not
   append a near-duplicate.
7. Append archived lines to `data/archive.md`.
8. Leave `data/candidates.md` unchanged (append-only; capture ≠ promotion).

Evidence is a br id, candidate date, or other grounded source — not "session".
Date a new or rewritten learnings line with today. Refresh a tier date only on
[reinforcement](#decay).

## Consolidation

Before saving `data/learnings.md`:

```bash
wc -l data/learnings.md
```

Over ~60 lines (or obviously over ~1,500 tokens): fold duplicates, shorten
prose, demote aging/perishable entries to `data/archive.md` until under.
Pinned entries are never dropped to shorten the file. The install.sh header
comment is part of the file; do not strip it and do not duplicate it.

## Decay

Lazy only — clocks tick during a curation pass, not in the background. Today's
date vs the marker date:

- Perishable ≥7d → check the named condition. Still open: refresh the date.
  Resolved, expired, or no longer checkable: archive.
- Aging ≥30d with no reinforcement this period → archive with reason.
- Pinned → never decays.

Reinforcement: the fact was used, confirmed, or re-derived this session.
Re-reading `data/learnings.md` is never reinforcement.

Never delete. Archive records keep the original line plus source file, tier
marker, date moved, and a one-line reason. Recovery is `rg` plus copy-back
into `data/learnings.md` via inspect-then-update.

```
- 2026-07-01 (from data/learnings.md, <!--a:2026-07-01-->, archived 2026-08-19): treehouse lease used --foo. Reason: aging, unreinforced 30d; flag renamed.
```

Copy the entry's actual tier marker into the provenance, not always `<!--a:…-->`.

## Retrieval

Not a write pass. Already in AGENTS.md:

- **Session start:** read `data/learnings.md` in full.
- **Pre-dispatch:** `rg -i "<repo-name>" data/` and paste at most 2–3 hits into
  the worker brief.

Do not dump `data/candidates.md` or `data/archive.md` into session context.
Need a past job? `br list -s closed --json`, `br search "<query>" -a --json`,
or `br show <id> --json`.

## Report

After a pass, one line per file touched: `unchanged` / `captured` / `rewritten`
/ `archived`. Counts: candidates appended, learnings promoted or folded, lines
archived, `wc -l` on `data/learnings.md`. Name any project-intrinsic finding
that still needs a worker PR. Do not paste file dumps.

## Do not

- Invent `memory/jobs.md`, `memory/decisions.md`, or extra markers/fields
- Put job lifecycle history in learnings (br owns that)
- Blind-append to `data/learnings.md` or rewrite `data/candidates.md`
- Delete entries; archive instead
- Commit `data/`, `projects/`, or `.beads/`
- Edit a target repo's `AGENTS.md` from this pane — spawn a worker
- Run capture/curation because a scout result "seems useful"; promotion still
  needs a curation pass
