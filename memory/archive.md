# Archive

<!--
Contract: cold tier for demoted learnings. Never loaded at session start.
Who writes: the orchestrator, during a curation pass (session end or every
~10 jobs, whichever comes first).
When: perishable entries whose named condition is expired (≥7d), or aging
entries with no reinforcement this period (≥30d), or any entry demoted to
enforce the learnings.md budget.
What: the original learning line plus provenance — source file, tier, date
moved, and a one-line reason. Shape:
  - YYYY-MM-DD (from learnings.md, <!--a:…-->, archived YYYY-MM-DD): <entry>. Reason: <why>

Never delete. Recovery is `rg` plus copy-back into learnings.md via
inspect-then-update.
-->
