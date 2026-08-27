// Command cmdp is the Go implementation of bin/cmdp for command-post.
package main

import (
	"fmt"
	"os"

	"github.com/0xb1ob/command-post/internal/cmdp"
)

func main() {
	if len(os.Args) < 2 {
		cmdp.PrintUsageMain()
	}
	e, err := cmdp.NewEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[cmdp] error: %s\n", err)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	var runErr error
	switch cmd {
	case "check":
		runErr = cmdp.CmdCheck(e, args)
	case "lease":
		runErr = cmdp.CmdLease(e, args)
	case "jobs":
		runErr = cmdp.CmdJobs(e, args)
	case "artifact":
		runErr = cmdp.CmdArtifact(e, args)
	case "gate":
		runErr = cmdp.CmdGate(e, args)
	case "dispatch":
		runErr = cmdp.CmdDispatch(e, args)
	case "doctor":
		runErr = cmdp.CmdDoctor(e, args)
	case "teardown":
		runErr = cmdp.CmdTeardown(e, args)
	case "status":
		runErr = cmdp.CmdStatus(e, args)
	case "models":
		runErr = cmdp.CmdModels(e, args)
	case "threads":
		runErr = cmdp.CmdThreads(e, args)
	case "relay":
		runErr = cmdp.CmdRelay(e, args)
	case "version":
		fmt.Printf("cmdp %s (%s)\n", cmdp.Version, cmdp.Commit)
	case "-h", "--help":
		cmdp.PrintUsageMain()
	default:
		cmdp.DieUsage("unknown command %s (want: check, lease, jobs, artifact, gate, dispatch, doctor, teardown, status, models, threads, or relay)", cmd)
	}
	if runErr != nil {
		cmdp.HandleErr(runErr)
	}
}
