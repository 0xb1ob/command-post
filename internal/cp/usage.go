package cp

import (
	"fmt"
	"os"
)

func printUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s check --project NAME [--base BRANCH] WORKTREE [WORKTREE...]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s lease --project NAME\n", prog)
	fmt.Fprintf(os.Stderr, "       %s jobs add|set|reported|done|list ...\n", prog)
	fmt.Fprintf(os.Stderr, "       %s artifact path|add|get ...\n", prog)
	fmt.Fprintf(os.Stderr, "       %s gate ID [--model M]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s doctor [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s dispatch --project NAME --br-id ID [--name ALIAS] [--template TNAME] [--task-file FILE] [--scope S|M|L] [--risk low|high] [-- CMD...]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s models [--json] [--cli ARGV0] [--family F] [--all]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s teardown ID\n", prog)
	fmt.Fprintf(os.Stderr, "       %s status [--json] [--html] [--serve [--port N]] [--origin ID]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads bind|unbind|list|events|status|log ...\n", prog)
	fmt.Fprintf(os.Stderr, "       %s relay render|post|status ...\n", prog)
	os.Exit(2)
}

func printThreadsUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s threads bind ID channel=CID thread_ts=TS\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads unbind ID\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads list [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads events ID [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads status ID [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s threads log ID\n", prog)
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "ID is the origin id stamped in the jobs.tsv origin column and is the\n")
	fmt.Fprintf(os.Stderr, "routing key: br_id -> origin (state/jobs.tsv) -> thread (state/threads.tsv).\n")
	fmt.Fprintf(os.Stderr, "origin=terminal is terminal dispatch and can never be bound.\n")
	fmt.Fprintf(os.Stderr, "events derives dispatched|reported|blocked|closed from the ledger; a job\n")
	fmt.Fprintf(os.Stderr, "with no origin is routable nowhere and is dropped, never broadcast.\n")
	fmt.Fprintf(os.Stderr, "Cross-origin br dep blockers keep phase blocked with id and title redacted.\n")
	os.Exit(2)
}

func printRelayUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s relay render --br-id ID --kind KIND [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s relay post --br-id ID --kind KIND\n", prog)
	fmt.Fprintf(os.Stderr, "       %s relay status [--json]\n", prog)
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "The relay is the only writer to Slack; the parent never posts. It renders\n")
	fmt.Fprintf(os.Stderr, "one templated, origin-keyed job event per call — never a parent turn and\n")
	fmt.Fprintf(os.Stderr, "never a STATUS BLOCK (terminal-only).\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "  KIND        dispatched | reported | blocked | closed\n")
	fmt.Fprintf(os.Stderr, "  templates   $CP_HOME/templates/thread-events.tsv overrides the built-ins\n")
	fmt.Fprintf(os.Stderr, "  tokens      $CP_HOME/state/slack/tokens.env (mode 600); CP_SLACK_TOKENS overrides\n")
	fmt.Fprintf(os.Stderr, "  logs        posts append to state/threads/<origin>.out.log (outbound only);\n")
	fmt.Fprintf(os.Stderr, "              refusals append to state/threads/dropped.log\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Exit: 0 posted, 1 refused (no origin, unbound origin, bad token file, API\n")
	fmt.Fprintf(os.Stderr, "error), 2 usage, %d not configured (no tokens — nothing posted).\n", exitNotConfigured)
	fmt.Fprintf(os.Stderr, "Inbound (Socket Mode) is not implemented: it needs an installed workspace\n")
	fmt.Fprintf(os.Stderr, "app. See docs/slack-install.md.\n")
	os.Exit(2)
}

func printStatusUsage() {
	fmt.Fprintf(os.Stderr, "usage: %s status [--json] [--html] [--serve [--port N]] [--origin ID] [--pane ALIAS]\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "       --serve default port is derived from CP_HOME (CP_STATUS_PORT overrides)\n")
	os.Exit(2)
}

func printDispatchUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s dispatch --project NAME --br-id ID [--name ALIAS] [--template TNAME] [--task-file FILE] [--scope S|M|L] [--risk low|high] [--origin ID] [-- CMD...]\n", prog)
	fmt.Fprintf(os.Stderr, "       --origin defaults to terminal (posts nowhere); a thread origin must be bound first\n")
	fmt.Fprintf(os.Stderr, "       default CMD: from data/routing.tsv or shipped implementer default\n")
	fmt.Fprintf(os.Stderr, "       --scope/--risk select a rubric row (default S/low); routing.tsv pins skip the rubric\n")
	fmt.Fprintf(os.Stderr, "       --template research uses the researcher role default\n")
	fmt.Fprintf(os.Stderr, "       worker CLI is probed before lease; missing CLI exits 2 (see bin/cp doctor)\n")
	fmt.Fprintf(os.Stderr, "       stdout: one JSON object {br_id,worker,worktree,branch,state,receipt}\n")
	fmt.Fprintf(os.Stderr, "       state=dispatched means the brief is queued, not received.\n")
	fmt.Fprintf(os.Stderr, "       receipt=unconfirmed with state=dispatched is a valid success — wait for mail; never re-dispatch.\n")
	fmt.Fprintf(os.Stderr, "       claude panes: receipt=unknown replaces unconfirmed (too-early-to-tell, not not-received) — same rule, wait for mail.\n")
	os.Exit(2)
}

func printTeardownUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s teardown ID [--research]\n", prog)
	fmt.Fprintf(os.Stderr, "       fail-closed: dirty or unpushed keeps the lease (ship). kind:research: clean + no local commits.\n")
	fmt.Fprintf(os.Stderr, "       --research: force research gate when br labels are unavailable. Does not close the br issue.\n")
	os.Exit(2)
}

func printJobsUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s jobs add ID worker=ALIAS worktree=PATH [branch=NAME]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s jobs set ID [worker=ALIAS] [worktree=PATH] [branch=NAME]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s jobs reported ID\n", prog)
	fmt.Fprintf(os.Stderr, "       %s jobs done ID\n", prog)
	fmt.Fprintf(os.Stderr, "       %s jobs list [--json]\n", prog)
	os.Exit(2)
}

func printArtifactUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s artifact path ID\n", prog)
	fmt.Fprintf(os.Stderr, "       %s artifact add ID FILE\n", prog)
	fmt.Fprintf(os.Stderr, "       %s artifact get ID\n", prog)
	os.Exit(2)
}

func printGateUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s gate ID [--model M]\n", prog)
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Headless quality gate (no pane, no lease, no mail).\n")
	fmt.Fprintf(os.Stderr, "Extracts the artifact with artifact get, reviews it against\n")
	fmt.Fprintf(os.Stderr, "templates/gate-rubric.md, records a gate:v1 comment.\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "  --model M     reviewer model (default: %s)\n", defaultGateModel)
	fmt.Fprintf(os.Stderr, "  CP_GATE_CMD   override reviewer command; reads prompt on stdin,\n")
	fmt.Fprintf(os.Stderr, "                writes a structured verdict on stdout\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Stdout JSON: br_id, verdict, attempt, flags, reasons, cause;\n")
	fmt.Fprintf(os.Stderr, "revisions when verdict=revise. cause is null on pass/revise;\n")
	fmt.Fprintf(os.Stderr, "on escalate it is policy, operational (first unparseable — re-run\n")
	fmt.Fprintf(os.Stderr, "gate once), or operational_persistent (prior gate was operational —\n")
	fmt.Fprintf(os.Stderr, "swap --model or surface to the caller; do not loop).\n")
	fmt.Fprintf(os.Stderr, "Reasons/revisions are truncated with an ellipsis if the JSON would\n")
	fmt.Fprintf(os.Stderr, "exceed a few hundred words. Never includes the artifact body.\n")
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Exit: 0 pass, 10 revise, 20 escalate; other nonzero is operational.\n")
	fmt.Fprintf(os.Stderr, "A pass does NOT close the issue or authorize implementation —\n")
	fmt.Fprintf(os.Stderr, "the orchestrator does that.\n")
	os.Exit(2)
}

func printDoctorUsage() {
	fmt.Fprintf(os.Stderr, "usage: %s doctor [--json]\n", os.Args[0])
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Read-only host and worker CLI discovery. No lease, no muxa dispatch,\n")
	fmt.Fprintf(os.Stderr, "no jobs writes. Exit 0 when host tools are present; worker CLI gaps\n")
	fmt.Fprintf(os.Stderr, "are reported, not a failure. Exit 2 when a host tool is missing.\n")
	os.Exit(2)
}

func printLeaseUsage() {
	fmt.Fprintf(os.Stderr, "usage: %s lease --project NAME\n", os.Args[0])
	os.Exit(2)
}
