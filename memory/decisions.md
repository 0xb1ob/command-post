# Dispatch decisions

<!--
Contract: append-only dispatch-decision log. Never loaded wholesale; greppable.
Who writes: the orchestrator, at dispatch time (before spawn).
When: once per job, immediately before spawning a worker.
What: one line — `YYYY-MM-DD routed <job> to <repo> because <reason>`.
Do not rewrite or delete lines. Post-mortems grep this file by repo or date.
-->
