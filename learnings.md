# Learnings

<!--
Contract: curated core. Always loaded at session start.
Budget: max ~60 lines / ~1,500 tokens. Over budget → consolidate or demote
until under before the file is saved.

Writes: inspect-then-update only. Read the whole file, classify the finding
as new / duplicate / superseding / obsoleting, then rewrite the affected
entry. Never blind-append. Duplicates fold in; superseded entries are
rewritten in place. Every write leaves the file more accurate, not merely
longer.

Entries: one line each, dated, evidence-backed. Shape:
  - YYYY-MM-DD what happened; what to do; evidence: memory/jobs.md#<job>. <!--tier-->
Tiers (trailing HTML comments):
  <!--P-->            pinned — never decays
  <!--a:YYYY-MM-DD--> aging — stale at ≥30 days since last reinforcement
  <!--p:YYYY-MM-DD--> perishable — stale at ≥7 days; must name a checkable
                      expiry condition (ticket, version, dated expectation)
Reinforcement counts only on real evidence of use this session. Re-reading
memory is never reinforcement.

Scope: cross-repo / orchestration knowledge only. Project-intrinsic facts
("repo X's tests need flag Y") go to that repo's AGENTS.md via a worker PR.

Promotion: candidates live in memory/jobs.md until a curation pass promotes
ones that generalize. Capture is not promotion.

Decay: evaluated lazily at curation (session end or every ~10 jobs). Stale
entries move to memory/archive.md with provenance — never delete.
-->

_none yet_
