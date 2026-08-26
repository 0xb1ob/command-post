package cp

import (
	"fmt"
)

func CmdJobs(e *Env, args []string) error {
	if len(args) == 0 {
		return usageError("missing add|set|reported|done|list")
	}
	switch args[0] {
	case "add":
		if len(args) < 2 {
			return usageError("add needs ID")
		}
		kv, err := parseRuntimeKV(args[2:])
		if err != nil {
			return err
		}
		return JobsAdd(e, args[1], kv)
	case "set":
		if len(args) < 2 {
			return usageError("set needs ID")
		}
		kv, err := parseRuntimeKV(args[2:])
		if err != nil {
			return err
		}
		return JobsSet(e, args[1], kv)
	case "reported":
		if len(args) < 2 {
			return usageError("reported needs ID")
		}
		return JobsReported(e, args[1], args[2:])
	case "done":
		if len(args) < 2 {
			return usageError("done needs ID")
		}
		return JobsDone(e, args[1], args[2:])
	case "list":
		jsonOut := false
		for _, a := range args[1:] {
			switch a {
			case "--json":
				jsonOut = true
			case "-h", "--help":
				printJobsUsage()
			default:
				return usageError("unknown list flag %s", a)
			}
		}
		if jsonOut {
			b, err := JobsListJSON(e)
			if err != nil {
				return err
			}
			fmt.Println(string(b))
			return nil
		}
		return JobsListTable(e)
	case "-h", "--help":
		printJobsUsage()
	default:
		return usageError("unknown jobs command %s (want: add, set, reported, done, list)", args[0])
	}
	return nil
}
