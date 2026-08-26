// Command cp is the Go implementation of bin/cp for command-post.
package main

import (
	"fmt"
	"os"

	"github.com/0xb1ob/command-post/internal/cp"
)

func main() {
	if len(os.Args) < 2 {
		cp.PrintUsageMain()
	}
	e, err := cp.NewEnv()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[cp] error: %s\n", err)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	var runErr error
	switch cmd {
	case "check":
		runErr = cp.CmdCheck(e, args)
	case "lease":
		runErr = cp.CmdLease(e, args)
	case "jobs":
		runErr = cp.CmdJobs(e, args)
	case "artifact":
		runErr = cp.CmdArtifact(e, args)
	case "gate":
		runErr = cp.CmdGate(e, args)
	case "dispatch":
		runErr = cp.CmdDispatch(e, args)
	case "doctor":
		runErr = cp.CmdDoctor(e, args)
	case "teardown":
		runErr = cp.CmdTeardown(e, args)
	case "status":
		runErr = cp.CmdStatus(e, args)
	case "models":
		runErr = cp.CmdModels(e, args)
	case "threads":
		runErr = cp.CmdThreads(e, args)
	case "relay":
		runErr = cp.CmdRelay(e, args)
	case "version":
		fmt.Printf("cp %s (%s)\n", cp.Version, cp.Commit)
	case "-h", "--help":
		cp.PrintUsageMain()
	default:
		cp.DieUsage("unknown command %s (want: check, lease, jobs, artifact, gate, dispatch, doctor, teardown, status, models, threads, or relay)", cmd)
	}
	if runErr != nil {
		cp.HandleErr(runErr)
	}
}
