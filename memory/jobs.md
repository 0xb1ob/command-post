# Job journal

<!--
Contract: append-only recall / evidence tier. Never loaded wholesale; greppable.
Who writes: the orchestrator, when processing a worker's final report.
When: every job completion, and mandatorily on failure / blocker.
What: one dated block per job — date, job id, target repo, outcome
(done / blocker / failed), PR link if any, and 0–3 candidate learnings.
Candidates answer: what failed or surprised; what would be done differently;
what the next dispatch to this repo should know. Most jobs yield zero
candidates; that is fine.

Failures / blockers: the block must include a one-sentence root cause plus
a candidate learning. That is where recurrence prevention lives.

Candidates stay here until a curation pass promotes ones that generalize
into learnings.md via inspect-then-update. Never edit old blocks; append only.
-->
