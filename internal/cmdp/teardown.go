package cmdp

import (
	"fmt"
	"os"
	"strings"
)

func assertCleanResearch(wt, branch string) error {
	dirty, _ := gitOutput(wt, "status", "--porcelain")
	if strings.TrimSpace(dirty) != "" {
		fmt.Fprintf(os.Stderr, "[cmdp] error: dirty worktree %s — keep the lease; clean porcelain, then retry teardown\n", wt)
		os.Exit(1)
	}
	base := defaultBaseBranch(wt)
	if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "origin/"+branch); err == nil {
		local, _ := gitOutput(wt, "rev-parse", "HEAD")
		remote, _ := gitOutput(wt, "rev-parse", "origin/"+branch)
		if local == remote {
			return nil
		}
		fmt.Fprintf(os.Stderr, "[cmdp] error: unpushed %s on %s (local tip != origin/%s) — keep the lease; push, then retry teardown\n", wt, branch, branch)
		os.Exit(1)
	}
	if upstream, err := gitOutput(wt, "rev-parse", "--abbrev-ref", "--verify", "@{u}"); err == nil && upstream != "" {
		local, _ := gitOutput(wt, "rev-parse", "HEAD")
		remote, _ := gitOutput(wt, "rev-parse", "@{u}")
		if local != remote {
			fmt.Fprintf(os.Stderr, "[cmdp] error: unpushed %s on %s (local %s != %s) — keep the lease; push, then retry teardown\n", wt, branch, truncHash(local), upstream)
			os.Exit(1)
		}
	}
	ahead := "0"
	if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", branch); err == nil {
		if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "origin/"+base); err == nil {
			ahead, _ = gitOutput(wt, "rev-list", "--count", "origin/"+base+".."+branch)
		}
	}
	if ahead != "" && ahead != "0" {
		fmt.Fprintf(os.Stderr, "[cmdp] error: research branch %s has %s unpushed commit(s) on %s — keep the lease; reset or push, then retry teardown\n", branch, ahead, wt)
		os.Exit(1)
	}
	return nil
}

func assertCleanAndPushed(wt, branch string) error {
	dirty, _ := gitOutput(wt, "status", "--porcelain")
	if strings.TrimSpace(dirty) != "" {
		fmt.Fprintf(os.Stderr, "[cmdp] error: dirty worktree %s — keep the lease; clean porcelain, then retry teardown\n", wt)
		os.Exit(1)
	}
	local, _ := gitOutput(wt, "rev-parse", "HEAD")
	if local == "" {
		return failError("cannot read HEAD in %s — keep the lease", wt)
	}
	if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "origin/"+branch); err == nil {
		remote, _ := gitOutput(wt, "rev-parse", "origin/"+branch)
		if local == remote {
			return nil
		}
	}
	if _, err := gitOutput(wt, "rev-parse", "--abbrev-ref", "--verify", "@{u}"); err == nil {
		remote, _ := gitOutput(wt, "rev-parse", "@{u}")
		if local == remote {
			return nil
		}
		upstream, _ := gitOutput(wt, "rev-parse", "--abbrev-ref", "@{u}")
		fmt.Fprintf(os.Stderr, "[cmdp] error: unpushed %s on %s (local %s != %s) — keep the lease; push, then retry teardown\n", wt, branch, truncHash(local), upstream)
		os.Exit(1)
	}
	if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "origin/"+branch); err == nil {
		fmt.Fprintf(os.Stderr, "[cmdp] error: unpushed %s on %s (local tip != origin/%s) — keep the lease; push, then retry teardown\n", wt, branch, branch)
		os.Exit(1)
	}
	headBranch, _ := gitOutput(wt, "symbolic-ref", "--quiet", "--short", "HEAD")
	if headBranch == branch {
		base := defaultBaseBranch(wt)
		if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "refs/remotes/origin/"+base); err == nil {
			remote, _ := gitOutput(wt, "rev-parse", "refs/remotes/origin/"+base)
			if local == remote {
				return nil
			}
		}
	}
	fmt.Fprintf(os.Stderr, "[cmdp] error: unpushed %s branch %s has no upstream and is not on origin — keep the lease; push, then retry teardown\n", wt, branch)
	os.Exit(1)
	return nil
}

func truncHash(s string) string {
	if len(s) > 12 {
		return s[:12]
	}
	return s
}

func CmdTeardown(e *Env, args []string) error {
	id := ""
	researchFlag := false
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-h", "--help":
			printTeardownUsage()
			os.Exit(2)
		case "--research":
			researchFlag = true
		default:
			if strings.HasPrefix(args[i], "-") {
				return usageError("unknown flag %s", args[i])
			}
			if id != "" {
				return usageError("teardown takes one ID")
			}
			id = args[i]
		}
	}
	if id == "" {
		return usageError("teardown needs ID")
	}
	if err := validateJobID(id); err != nil {
		return err
	}
	row, ok := jobsLookup(e, id)
	if !ok {
		return failError("no runtime row for %s — nothing to tear down (bin/cmdp jobs list)", id)
	}
	if row.Worktree == "" {
		return failError("runtime row %s has an empty worktree — keep the lease; fix bin/cmdp jobs", id)
	}
	if row.Worker == "" {
		return failError("runtime row %s has an empty worker — keep the lease; fix bin/cmdp jobs", id)
	}
	if row.Branch == "" {
		return failError("runtime row %s has an empty branch — keep the lease; fix bin/cmdp jobs", id)
	}
	if st, err := os.Stat(row.Worktree); err != nil || !st.IsDir() {
		return failError("worktree %s is missing — keep the lease; restore the path or fix the jobs row", row.Worktree)
	}
	kind := ""
	if researchFlag {
		kind = "research"
	} else if v, err := brIssueLabelValue(e, id, "kind:"); err == nil {
		kind = v
	}
	if kind == "research" {
		if err := assertCleanResearch(row.Worktree, row.Branch); err != nil {
			return err
		}
	} else {
		if err := assertCleanAndPushed(row.Worktree, row.Branch); err != nil {
			return err
		}
	}
	if err := artifactTeardownGuard(e, id); err != nil {
		return err
	}
	if err := treehouseReturnForce(e, row.Worktree); err != nil {
		return err
	}
	if ok, _ := workerInWho(e, row.Worker); ok {
		if err := requireMuxaBin(); err != nil {
			return err
		}
		_ = runCmd("muxa", "kill", row.Worker)
	}
	if err := JobsDone(e, id, nil); err != nil {
		return err
	}
	artifactTeardownClean(e, id)
	return nil
}
