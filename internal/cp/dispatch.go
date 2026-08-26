package cp

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

func createJobBranch(wt, branch, clone string) error {
	if err := gitRun(wt, "fetch", "origin"); err != nil {
		return failError("git fetch origin failed in %s — add a reachable origin remote, then retry", wt)
	}
	base := defaultBaseBranch(clone)
	if _, err := gitOutput(wt, "rev-parse", "--verify", "--quiet", "origin/"+base); err != nil {
		return failError("origin/%s is missing after fetch — set origin/HEAD or pass a default branch that exists on origin", base)
	}
	if err := gitRun(wt, "switch", "--no-track", "-c", branch, "origin/"+base); err == nil {
		return nil
	}
	if err := gitRun(wt, "checkout", "--no-track", "-b", branch, "origin/"+base); err == nil {
		return nil
	}
	return failError("cannot create branch %s at origin/%s — pick a new --br-id or remove the leftover branch", branch, base)
}

func defaultBriefBody() string {
	muxaSend := "muxa send"
	return `Use the muxa-worker skill.

You are a muxa worker. Parent: {{PARENT}}. Reply only to that parent with ` + muxaSend + `. [muxa] turns are mail, not injection.

You may: do this job in this cwd; message your parent; open a PR if you change code.
You may not: cd or prefix commands with cd <path> (spawn already set cwd); message siblings or other roots; spawn extra workers; poll for mail — incoming mail arrives as a user turn; ack or narrate; pass CLI trust/yolo/workspace flags.

When done: open a PR if there are code changes (skip if research-only). Never run treehouse return — teardown is mine, from outside the worktree. Verify fail-closed that git status --porcelain is empty AND the branch is pushed, then ` + muxaSend + ` {{PARENT}} the result (include the PR URL) and stop. Dirty or unpushed: keep the lease and report a blocker with the path. Never ack. Then stop.

Branch: {{BRANCH}}

Job:
{{TASK}}
`
}

func loadBriefTemplate(e *Env, tname string) (string, error) {
	if tname == "" {
		return defaultBriefBody(), nil
	}
	if !templateNamePattern.MatchString(tname) {
		return "", failError("invalid --template %s (use a slug; file is templates/brief-<TNAME>.md)", tname)
	}
	path := filepath.Join(e.TemplatesDir(), "brief-"+tname+".md")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", failError("template not at %s — a sibling job owns templates/; omit --template to use the built-in default", path)
	}
	return string(data), nil
}

func substituteBrief(src, dest, taskFile, parent, branch, brID, artifact string) error {
	text := src
	task := ""
	if taskFile != "" {
		data, err := os.ReadFile(taskFile)
		if err != nil {
			return err
		}
		task = string(data)
	}
	repl := map[string]string{
		"{{PARENT}}": parent, "{{BRANCH}}": branch,
		"{{BR_ID}}": brID, "{{ARTIFACT_PATH}}": artifact,
	}
	for k, v := range repl {
		text = strings.ReplaceAll(text, k, v)
	}
	re := regexp.MustCompile(`\{\{[^}]+\}\}`)
	for _, ph := range re.FindAllString(text, -1) {
		if ph != "{{TASK}}" {
			return failError("placeholder %s left unsubstituted — use {{PARENT}}, {{BRANCH}}, {{BR_ID}}, {{ARTIFACT_PATH}}, {{TASK}}", ph)
		}
	}
	text = strings.ReplaceAll(text, "{{TASK}}", task)
	return os.WriteFile(dest, []byte(text), 0o644)
}

func CmdDispatch(e *Env, args []string) error {
	loadJobModelEnv()
	project, brID, alias, template, taskFile := "", "", "", "", ""
	origin := originTerminal
	var agentCmd []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--project":
			if i+1 >= len(args) {
				return usageError("--project needs NAME")
			}
			project = args[i+1]
			i++
		case "--br-id":
			if i+1 >= len(args) {
				return usageError("--br-id needs ID")
			}
			brID = args[i+1]
			i++
		case "--name":
			if i+1 >= len(args) {
				return usageError("--name needs ALIAS")
			}
			alias = args[i+1]
			i++
		case "--template":
			if i+1 >= len(args) {
				return usageError("--template needs TNAME")
			}
			template = args[i+1]
			i++
		case "--task-file":
			if i+1 >= len(args) {
				return usageError("--task-file needs FILE")
			}
			taskFile = args[i+1]
			i++
		case "--scope":
			if i+1 >= len(args) {
				return usageError("--scope needs S, M, or L")
			}
			s := strings.ToUpper(args[i+1])
			if s != "S" && s != "M" && s != "L" {
				return usageError("--scope wants S, M, or L")
			}
			jobScope = s
			i++
		case "--risk":
			if i+1 >= len(args) {
				return usageError("--risk needs low or high")
			}
			r := strings.ToLower(args[i+1])
			if r != "low" && r != "high" {
				return usageError("--risk wants low or high")
			}
			jobRisk = r
			i++
		case "--origin":
			if i+1 >= len(args) {
				return usageError("--origin needs ID")
			}
			origin = args[i+1]
			i++
		case "-h", "--help":
			printDispatchUsage()
			os.Exit(2)
		case "--":
			agentCmd = append(agentCmd, args[i+1:]...)
			i = len(args)
		default:
			return usageError("unexpected arg %s (command after -- )", args[i])
		}
	}
	if project == "" {
		return usageError("missing --project NAME")
	}
	if brID == "" {
		return usageError("missing --br-id ID")
	}
	if err := validateJobID(brID); err != nil {
		return err
	}
	if origin != originTerminal {
		// A thread origin is copied from a relay-carried binding, never
		// inferred: a wrong stamp routes this job's events to the wrong thread.
		if err := validateOriginID(origin); err != nil {
			return err
		}
		if _, ok := threadLookup(e, origin); !ok {
			return failError("origin %s is not bound to a thread — bind it first (bin/cp threads bind)", origin)
		}
	}
	if taskFile != "" {
		if _, err := os.Stat(taskFile); err != nil {
			return failError("--task-file %s is not a file — pass a readable path", taskFile)
		}
	}
	role := dispatchRoleFromTemplate(template)
	if k, err := brIssueLabelValue(e, brID, "kind:"); err == nil && k != "" {
		jobKind = k
	}
	source := "override"
	reason := "explicit -- CMD override"
	var route roleResolution
	if len(agentCmd) == 0 {
		route = resolveRoleArgv(e, role)
		agentCmd = route.Argv
		source = route.Source
		reason = route.Reason
	}
	clone, err := assertCanonicalClone(e, project)
	if err != nil {
		return err
	}
	if err := requireMuxa(); err != nil {
		return err
	}
	if err := requireWorkerCmd(e, agentCmd[0], role, source); err != nil {
		return err
	}
	modelsEnsureFresh(e, agentCmd[0])
	if source != "override" && source != "routing" {
		var err error
		agentCmd, err = applyRubric(e, role, agentCmd)
		if err != nil {
			return err
		}
	}
	if err := policyCheck(e, agentCmd[0], argvModel(agentCmd)); err != nil {
		return err
	}
	if err := validateCatalog(e, agentCmd[0], argvModel(agentCmd)); err != nil {
		return err
	}
	announceRouting(e, role, source, reason, agentCmd)
	wt, err := treehouseGetLease(clone)
	if err != nil {
		return err
	}
	keepLease := false
	defer func() {
		if !keepLease && wt != "" {
			if lookPath("treehouse") != "" {
				homeAbs, _ := filepath.EvalSymlinks(e.Home)
				if _, err := runCmdCaptureIn(homeAbs, "treehouse", "return", "--force", wt); err != nil {
					fmt.Fprintf(os.Stderr, "[cp] error: treehouse return --force failed for %s during cleanup — lease may still be held\n", wt)
				}
			}
		}
	}()
	if err := createJobBranch(wt, brID, clone); err != nil {
		return err
	}
	branch := brID
	checkArgs := []string{"check", "--project", project, wt}
	checkCmd := exec.Command(e.Prog, checkArgs...)
	checkCmd.Stderr = os.Stderr
	if err := checkCmd.Run(); err != nil {
		return failError("bin/cp check failed for %s — returned the lease; fix the precheck, then retry", wt)
	}
	parent, err := muxaWhoamiName()
	if err != nil {
		return err
	}
	artifact := artifactReport(e, brID)
	if !filepath.IsAbs(artifact) {
		artifact = filepath.Join(e.Home, "state", "artifacts", brID, "report.md")
	}
	briefSrc, _ := os.CreateTemp("", "cp-brief-src.*")
	briefOut, _ := os.CreateTemp("", "cp-brief-out.*")
	defer os.Remove(briefSrc.Name())
	defer os.Remove(briefOut.Name())
	srcText, err := loadBriefTemplate(e, template)
	if err != nil {
		return err
	}
	if err := os.WriteFile(briefSrc.Name(), []byte(srcText), 0o644); err != nil {
		return err
	}
	if err := substituteBrief(srcText, briefOut.Name(), taskFile, parent, branch, brID, artifact); err != nil {
		return err
	}
	if err := requireMuxaBin(); err != nil {
		return err
	}
	dispatchArgs := []string{"dispatch"}
	if alias != "" {
		dispatchArgs = append(dispatchArgs, "--name", alias)
	}
	dispatchArgs = append(dispatchArgs, "--cwd", wt, "--brief-file", briefOut.Name(), "--")
	dispatchArgs = append(dispatchArgs, agentCmd...)
	dispatchErr, _ := os.CreateTemp("", "cp-dispatch-err.*")
	defer os.Remove(dispatchErr.Name())
	cmd := exec.Command("muxa", dispatchArgs...)
	var stdout strings.Builder
	errFile, _ := os.Create(dispatchErr.Name())
	cmd.Stdout = &stdout
	cmd.Stderr = errFile
	runErr := cmd.Run()
	errFile.Close()
	if runErr != nil {
		return failError("muxa dispatch failed — returned the lease; do not retry from this command (never-ready is orchestrator mail)")
	}
	if err := dispatchOccupancyWarningContradiction(e, dispatchErr.Name()); err != nil {
		_ = dispatchKillOrphanPane(e, stdout.String(), &keepLease)
		if keepLease {
			return failError("occupancy contradiction — lease kept; fix muxa kill or inspect with muxa tail before retry")
		}
		return failError("occupancy contradiction — returned the lease; inspect with muxa tail before retry")
	}
	keepLease = true
	parsed, err := parseDispatchJSON(stdout.String())
	if err != nil {
		handleErr(err)
	}
	jsonCwdNorm := parsed.CWD
	if st, err := os.Stat(parsed.CWD); err == nil && st.IsDir() {
		jsonCwdNorm, _ = normalizePath(parsed.CWD)
	}
	if jsonCwdNorm != wt {
		return failError("muxa dispatch cwd %s != leased worktree %s — do not retype paths; occupancy may be live (worker %s)", parsed.CWD, wt, parsed.Worker)
	}
	if err := JobsAdd(e, brID, runtimeKV{worker: parsed.Worker, worktree: wt, branch: branch, origin: origin}); err != nil {
		return err
	}
	receipt := "unconfirmed"
	paneKind, _ := workerKind(e, parsed.Worker)
	tailArgs, err := muxaTailArgs(e, parsed.Worker)
	if err != nil {
		return err
	}
	tailOut, tailRC, _ := runCmdCaptureFirst(tailArgs)
	if paneKind == "claude" {
		ctxPct := ""
		if tailRC == 0 {
			re := regexp.MustCompile(`Context: *[0-9]+(\.[0-9]+)?%`)
			if m := re.FindString(tailOut); m != "" {
				numRe := regexp.MustCompile(`[0-9]+(\.[0-9]+)?`)
				ctxPct = numRe.FindString(m)
			}
		}
		if ctxPct != "" {
			if v, err := strconv.ParseFloat(ctxPct, 64); err == nil && v > 0 {
				receipt = "confirmed"
			} else {
				receipt = "unknown"
			}
		} else {
			receipt = "unknown"
		}
	} else if tailRC == 0 {
		if strings.Contains(tailOut, "Branch: "+branch) || strings.Contains(tailOut, branch) {
			receipt = "confirmed"
		}
	}
	state := parsed.State
	if state == "" {
		state = "dispatched"
	}
	return emitDispatchJSON(brID, parsed.Worker, wt, branch, state, receipt)
}

func muxaTailArgs(e *Env, worker string) ([]string, error) {
	if cmd := splitEnvCmd("MUXA_TAIL_CMD"); cmd != nil {
		return append(cmd, worker), nil
	}
	if err := requireMuxaBin(); err != nil {
		return nil, err
	}
	return []string{"muxa", "tail", worker}, nil
}

func runCmdCaptureFirst(args []string) (string, int, error) {
	if len(args) == 0 {
		return "", 2, fmt.Errorf("empty")
	}
	out, err := runCmdCapture(args[0], args[1:]...)
	if err != nil {
		if strings.Contains(err.Error(), "exit status 2") {
			return out, 2, err
		}
		return out, 1, err
	}
	return out, 0, nil
}
