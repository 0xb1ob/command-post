package cp

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func assertCanonicalClone(e *Env, name string) (string, error) {
	if !projectNamePattern.MatchString(name) {
		return "", failError("invalid project name: %s (use the data/projects.md Name slug)", name)
	}
	clone := strings.TrimRight(e.Home, "/") + "/projects/" + name
	if st, err := os.Stat(clone); err != nil || !st.IsDir() {
		return "", failError("project clone not at %s (command-post home %s). Clone into projects/%s; not ~/%s.", clone, e.Home, name, name)
	}
	cloneAbs, err := filepath.EvalSymlinks(clone)
	if err != nil {
		return "", failError("project clone not at %s (command-post home %s). Clone into projects/%s; not ~/%s.", clone, e.Home, name, name)
	}
	homeProj := filepath.Join(os.Getenv("HOME"), name)
	if st, err := os.Stat(homeProj); err == nil && st.IsDir() {
		homeAbs, _ := filepath.EvalSymlinks(homeProj)
		if cloneAbs == homeAbs {
			return "", failError("projects/%s resolves to ~/%s (%s). Lease only from command-post projects/<name>.", name, name, cloneAbs)
		}
	}
	toplevel, err := gitOutput(cloneAbs, "rev-parse", "--show-toplevel")
	if err != nil {
		return "", failError("not a git clone: %s", cloneAbs)
	}
	toplevel, _ = filepath.EvalSymlinks(toplevel)
	if toplevel != cloneAbs {
		return "", failError("nested wrong git: %s is inside %s — need a clone at projects/%s", cloneAbs, toplevel, name)
	}
	gitDir := filepath.Join(cloneAbs, ".git")
	if st, err := os.Stat(gitDir); err != nil || !st.IsDir() {
		return "", failError("projects/%s is not a primary clone (%s/.git is not a directory; another repo's worktree?)", name, cloneAbs)
	}
	common, err := absGitCommon(cloneAbs)
	if err != nil {
		return "", failError("cannot resolve git-common-dir for %s", cloneAbs)
	}
	gitReal, _ := filepath.EvalSymlinks(gitDir)
	if common != gitReal {
		return "", failError("projects/%s git-common-dir is %s, not %s. Lease only from the canonical clone.", name, common, gitReal)
	}
	return cloneAbs, nil
}

func resolveWorktrees(clone string, worktrees []string) []string {
	out := make([]string, 0, len(worktrees))
	for _, arg := range worktrees {
		raw := arg
		if !filepath.IsAbs(arg) {
			raw = filepath.Join(clone, arg)
		}
		if p, err := normalizePath(raw); err == nil && p != "" {
			out = append(out, p)
		} else {
			out = append(out, raw)
		}
	}
	return out
}

func checkGitPreflight(clone, base string, worktrees []string) bool {
	fail := false
	common, err := absGitCommon(clone)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[cp] fail: repo %s has no resolvable git dir\n", clone)
		return false
	}
	if base == "" {
		base = defaultBaseBranch(clone)
	}
	log("base branch %s", base)
	primary, _ := primaryWorktree(clone)
	if primary == "" {
		fmt.Fprintln(os.Stderr, "[cp] fail: primary checkout: git worktree list returned nothing")
		fail = true
	} else if st, err := os.Stat(primary); err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "[cp] fail: primary %s does not exist\n", primary)
		fail = true
		primary = ""
	} else {
		primary, _ = filepath.EvalSymlinks(primary)
		branch, _ := gitOutput(primary, "symbolic-ref", "--quiet", "--short", "HEAD")
		if branch == "" {
			fmt.Fprintf(os.Stderr, "[cp] fail: primary %s is detached (want %s)\n", primary, base)
			fail = true
		} else if branch == base {
			log("primary %s on %s", primary, base)
		} else {
			fmt.Fprintf(os.Stderr, "[cp] fail: primary %s on %s (want %s)\n", primary, branch, base)
			fail = true
		}
	}
	for _, arg := range worktrees {
		raw := arg
		if !filepath.IsAbs(arg) {
			raw = filepath.Join(clone, arg)
		}
		if st, err := os.Stat(raw); err != nil || !st.IsDir() {
			fmt.Fprintf(os.Stderr, "[cp] fail: worktree %s does not exist\n", arg)
			fail = true
			continue
		}
		wt, _ := filepath.EvalSymlinks(raw)
		wtCommon, err := absGitCommon(wt)
		if err != nil || wtCommon == "" {
			fmt.Fprintf(os.Stderr, "[cp] fail: worktree %s is not a git worktree\n", wt)
			fail = true
		} else if wtCommon != common {
			fmt.Fprintf(os.Stderr, "[cp] fail: worktree %s belongs to another repo (%s)\n", wt, wtCommon)
			fail = true
		} else if primary != "" && wt == primary {
			fmt.Fprintf(os.Stderr, "[cp] fail: worktree %s is the primary checkout, not a linked worktree\n", wt)
			fail = true
		} else {
			branch, _ := gitOutput(wt, "symbolic-ref", "--quiet", "--short", "HEAD")
			if branch == "" {
				branch = "detached"
			}
			log("worktree %s linked on %s", wt, branch)
		}
	}
	return !fail
}

func CmdCheck(e *Env, args []string) error {
	project := ""
	base := ""
	var worktrees []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--project":
			if i+1 >= len(args) {
				return usageError("--project needs NAME")
			}
			project = args[i+1]
			i++
		case "--base":
			if i+1 >= len(args) {
				return usageError("--base needs BRANCH")
			}
			base = args[i+1]
			i++
		case "-h", "--help":
			printUsage()
			os.Exit(2)
		case "--":
			worktrees = append(worktrees, args[i+1:]...)
			i = len(args)
		default:
			if strings.HasPrefix(args[i], "-") {
				return usageError("unknown flag %s", args[i])
			}
			worktrees = append(worktrees, args[i])
		}
	}
	if project == "" {
		return usageError("missing --project NAME")
	}
	if len(worktrees) == 0 {
		return usageError("missing WORKTREE")
	}
	clone, err := assertCanonicalClone(e, project)
	if err != nil {
		return err
	}
	log("clone %s", clone)
	rc := 0
	if !checkGitPreflight(clone, base, worktrees) {
		rc = 1
	}
	if err := requireMuxa(); err != nil {
		return err
	}
	if rc == 0 {
		resolved := resolveWorktrees(clone, worktrees)
		if err := checkOccupancy(e, resolved); err != nil {
			if ee, ok := err.(*exitError); ok && ee.code == 1 {
				rc = 1
			} else {
				return err
			}
		}
	}
	if rc != 0 {
		os.Exit(1)
	}
	log("ok")
	return nil
}

func CmdLease(e *Env, args []string) error {
	project := ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--project":
			if i+1 >= len(args) {
				return usageError("--project needs NAME")
			}
			project = args[i+1]
			i++
		case "-h", "--help":
			printLeaseUsage()
			os.Exit(2)
		default:
			return usageError("unexpected arg %s", args[i])
		}
	}
	if project == "" {
		return usageError("missing --project NAME")
	}
	clone, err := assertCanonicalClone(e, project)
	if err != nil {
		return err
	}
	wt, err := treehouseGetLease(clone)
	if err != nil {
		return err
	}
	fmt.Println(wt)
	return nil
}

func treehouseGetLease(clone string) (string, error) {
	if err := requireTreehouse(); err != nil {
		return "", err
	}
	out, err := runCmdCaptureIn(clone, "treehouse", "get", "--lease")
	if err != nil {
		return "", failError("treehouse get --lease failed in %s — register the canonical clone and retry", clone)
	}
	out = strings.ReplaceAll(out, "\r", "")
	lines := splitLines(out)
	path := ""
	for _, l := range lines {
		if strings.TrimSpace(l) != "" {
			path = l
		}
	}
	if path == "" {
		return "", failError("treehouse get --lease printed no path — expect the absolute worktree on stdout")
	}
	if st, err := os.Stat(path); err != nil || !st.IsDir() {
		return "", failError("treehouse get --lease printed %s which is not a directory — check the clone registration", path)
	}
	return normalizePath(path)
}

func treehouseReturnForce(e *Env, wt string) error {
	if err := requireTreehouse(); err != nil {
		return err
	}
	homeAbs, _ := filepath.EvalSymlinks(e.Home)
	wtAbs, _ := normalizePath(wt)
	if homeAbs == wtAbs {
		return failError("refuse treehouse return: worktree is the command-post HOME %s — teardown must run from outside the worktree", homeAbs)
	}
	if strings.HasPrefix(homeAbs, wtAbs+"/") {
		return failError("refuse treehouse return: command-post HOME %s is inside worktree %s — teardown must run from outside the worktree", homeAbs, wtAbs)
	}
	if _, err := runCmdCaptureIn(homeAbs, "treehouse", "return", "--force", wt); err != nil {
		return failError("treehouse return --force failed for %s — lease may still be held; retry from %s", wt, homeAbs)
	}
	return nil
}
