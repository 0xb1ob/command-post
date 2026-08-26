package cp

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

func gatePriorState(e *Env, id string) (attempt, priorRevise, priorOperational int, err error) {
	raw, err := brCommentsList(e, id)
	if err != nil {
		return 0, 0, 0, err
	}
	var comments []map[string]any
	if err := json.Unmarshal([]byte(raw), &comments); err != nil {
		return 0, 0, 0, usageError("br comments list --json: not JSON")
	}
	verdictRe := regexp.MustCompile(`(?i)^\s*verdict\s*:\s*revise\s*$`)
	opCauseRe := regexp.MustCompile(`(?i)^\s*cause\s*:\s*operational\s*$`)
	unparseableRe := regexp.MustCompile(`(?i)reviewer output unparseable after one retry`)
	n := 0
	var lastGate string
	for _, c := range comments {
		text, _ := c["text"].(string)
		if text == "" {
			continue
		}
		first := text
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			first = text[:i]
		}
		if first != "gate:v1" {
			continue
		}
		n++
		lastGate = text
		for _, line := range splitLines(text) {
			if verdictRe.MatchString(line) {
				priorRevise = 1
				break
			}
		}
	}
	if lastGate != "" {
		for _, line := range splitLines(lastGate) {
			if opCauseRe.MatchString(line) {
				priorOperational = 1
				break
			}
		}
		if priorOperational == 0 && unparseableRe.MatchString(lastGate) {
			priorOperational = 1
		}
	}
	return n + 1, priorRevise, priorOperational, nil
}

type gateParsed struct {
	Verdict   string            `json:"verdict"`
	Reasons   []string          `json:"reasons"`
	Flags     map[string]string `json:"flags"`
	Revisions []string          `json:"revisions"`
	Cause     string            `json:"cause,omitempty"`
}

func parseGateVerdict(text string) (*gateParsed, error) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	if strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("empty")
	}
	headerRe := regexp.MustCompile(`(?i)^\s*(?:\*\*)?(verdict|reasons|flags|revisions|destructive_scope|scope_growth|blocking_unknowns)(?:\*\*)?\s*:\s*(.*)$`)
	token := func(rest string) string {
		rest = strings.Trim(strings.Trim(rest, "*"), " ")
		if rest == "" {
			return ""
		}
		t := strings.Fields(rest)[0]
		return strings.Trim(strings.TrimRight(t, ",;"), "*")
	}
	var verdict string
	flags := map[string]string{}
	var reasons, revisions []string
	var section string
	for _, rawLine := range splitLines(text) {
		line := strings.TrimSpace(rawLine)
		if strings.HasPrefix(line, "```") {
			continue
		}
		if m := headerRe.FindStringSubmatch(rawLine); m != nil {
			key := strings.ToLower(m[1])
			rest := m[2]
			switch key {
			case "verdict":
				v := token(rest)
				if v == "pass" || v == "revise" || v == "escalate" {
					verdict = v
				}
				section = ""
			case "destructive_scope", "scope_growth", "blocking_unknowns":
				v := strings.ToLower(token(rest))
				if v == "yes" || v == "no" {
					flags[key] = v
				}
				section = ""
			case "reasons", "flags", "revisions":
				section = key
			}
			continue
		}
		if section == "reasons" || section == "revisions" {
			bullet := strings.TrimSpace(rawLine)
			if strings.HasPrefix(bullet, "-") || strings.HasPrefix(bullet, "*") {
				item := strings.TrimSpace(bullet[1:])
				if item != "" {
					if section == "reasons" {
						reasons = append(reasons, item)
					} else {
						revisions = append(revisions, item)
					}
				}
			}
		}
	}
	need := []string{"destructive_scope", "scope_growth", "blocking_unknowns"}
	if verdict == "" {
		return nil, fmt.Errorf("missing verdict")
	}
	for _, k := range need {
		if _, ok := flags[k]; !ok {
			return nil, fmt.Errorf("missing flag %s", k)
		}
	}
	return &gateParsed{Verdict: verdict, Reasons: reasons, Flags: flags, Revisions: revisions}, nil
}

func runGateReviewer(e *Env, promptFile, model, outFile string) error {
	if cmdEnv := os.Getenv("CP_GATE_CMD"); cmdEnv != "" {
		parts := strings.Fields(cmdEnv)
		in, err := os.Open(promptFile)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(outFile)
		if err != nil {
			return err
		}
		defer out.Close()
		cmd := exec.Command(parts[0], parts[1:]...)
		cmd.Stdin = in
		cmd.Stdout = out
		return cmd.Run()
	}
	role := resolveRoleArgv(e, "gate-reviewer")
	if err := requireWorkerCmd(e, role.Argv0, "gate-reviewer", role.Source); err != nil {
		return err
	}
	prompt, err := os.ReadFile(promptFile)
	if err != nil {
		return err
	}
	bin := role.Argv0
	if bin == "agent" || bin == "cursor-agent" {
		out, err := runCmdCapture(bin, "--print", "--mode", "ask", "--output-format", "text", "--model", model, "--", string(prompt))
		if err != nil {
			return nil
		}
		return os.WriteFile(outFile, []byte(out), 0o644)
	}
	fmt.Fprintf(os.Stderr, "[cp] error: gate-reviewer CLI %q is not supported for headless gate (set CP_GATE_CMD to override)\n", bin)
	os.Exit(2)
	return nil
}

func applyGatePolicy(d *gateParsed, attempt int, brID string, priorRevise int, commentFile, jsonFile string) (string, error) {
	flags := map[string]string{}
	for k, v := range d.Flags {
		vl := strings.ToLower(v)
		if vl != "yes" && vl != "no" {
			vl = "no"
		}
		flags[k] = vl
	}
	verdict := d.Verdict
	reasons := append([]string{}, d.Reasons...)
	revisions := append([]string{}, d.Revisions...)
	var escalateCause string
	if d.Cause == "operational" || d.Cause == "operational_persistent" {
		escalateCause = d.Cause
	}
	need := []string{"destructive_scope", "scope_growth", "blocking_unknowns"}
	var forced []string
	for _, k := range need {
		if flags[k] == "yes" {
			forced = append(forced, k)
		}
	}
	if len(forced) > 0 {
		verdict = "escalate"
		escalateCause = "policy"
		note := "flag forced escalate: " + strings.Join(forced, ", ")
		if !containsStr(reasons, note) {
			reasons = append(reasons, note)
		}
	}
	if priorRevise == 1 && verdict == "revise" {
		verdict = "escalate"
		escalateCause = "policy"
		note := "attempt cap: a prior revise already exists (one revision max)"
		if !containsStr(reasons, note) {
			reasons = append(reasons, note)
		}
	}
	if verdict == "escalate" && escalateCause == "" {
		escalateCause = "policy"
	}
	var cause any
	if verdict == "escalate" {
		cause = escalateCause
	}
	shortItems := func(items []string) []string {
		var out []string
		for _, r := range items {
			one := strings.Join(strings.Fields(r), " ")
			if one != "" {
				out = append(out, one)
			}
		}
		return out
	}
	rs := shortItems(reasons)
	rvs := shortItems(revisions)
	if verdict != "revise" {
		rvs = nil
	}
	payload := func(rs, rvs []string) map[string]any {
		o := map[string]any{
			"br_id": brID, "verdict": verdict, "attempt": attempt,
			"flags": flags, "reasons": rs, "cause": cause,
		}
		if verdict == "revise" {
			o["revisions"] = rvs
		}
		return o
	}
	const cap = 300
	wc := func(rs, rvs []string) int {
		s, _ := marshalPythonJSON(payload(rs, rvs))
		return len(strings.Fields(s))
	}
	if wc(rs, rvs) > cap {
		rs = fitWordCap(rs, func(trial []string) int { return wc(trial, []string{}) })
		if verdict == "revise" {
			rvs = fitWordCap(rvs, func(trial []string) int { return wc(rs, trial) })
		}
	}
	lines := []string{
		"gate:v1",
		fmt.Sprintf("attempt: %d", attempt),
		fmt.Sprintf("verdict: %s", verdict),
	}
	if verdict == "escalate" && escalateCause != "" {
		lines = append(lines, fmt.Sprintf("cause: %s", escalateCause))
	}
	lines = append(lines, "flags:",
		fmt.Sprintf("destructive_scope: %s", flags["destructive_scope"]),
		fmt.Sprintf("scope_growth: %s", flags["scope_growth"]),
		fmt.Sprintf("blocking_unknowns: %s", flags["blocking_unknowns"]),
		"reasons:")
	for _, r := range rs {
		lines = append(lines, "- "+r)
	}
	if verdict == "revise" {
		lines = append(lines, "revisions:")
		for _, r := range rvs {
			lines = append(lines, "- "+r)
		}
	}
	if err := os.WriteFile(commentFile, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return "", err
	}
	b, _ := marshalPythonJSON(payload(rs, rvs))
	if err := os.WriteFile(jsonFile, append([]byte(b), '\n'), 0o644); err != nil {
		return "", err
	}
	return verdict, nil
}

func containsStr(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func fitWordCap(items []string, measure func([]string) int) []string {
	const wordCap = 300
	if measure(items) <= wordCap {
		out := make([]string, len(items))
		copy(out, items)
		return out
	}
	kept := []string{}
	for _, item := range items {
		trial := append(append([]string{}, kept...), item)
		if measure(trial) <= wordCap {
			kept = trial
			continue
		}
		words := strings.Fields(item)
		chosen := ""
		found := false
		for n := len(words); n >= 0; n-- {
			var trialItem string
			if n == 0 {
				trialItem = "..."
			} else {
				trialItem = strings.Join(words[:n], " ") + " ..."
			}
			trial2 := append(append([]string{}, kept...), trialItem)
			if measure(trial2) <= wordCap {
				chosen = trialItem
				found = true
				break
			}
		}
		if found {
			kept = append(kept, chosen)
		} else if len(kept) == 0 {
			kept = []string{"..."}
		} else if !strings.HasSuffix(kept[len(kept)-1], "...") {
			if measure(append(kept, "...")) <= wordCap {
				kept = append(kept, "...")
			} else {
				lw := strings.Fields(kept[len(kept)-1])
				for n := len(lw); n >= 0; n-- {
					var trialItem string
					if n == 0 {
						trialItem = "..."
					} else {
						trialItem = strings.Join(lw[:n], " ") + " ..."
					}
					trial3 := append(append([]string{}, kept[:len(kept)-1]...), trialItem)
					if measure(trial3) <= wordCap {
						kept[len(kept)-1] = trialItem
						break
					}
				}
			}
		}
		break
	}
	return kept
}

func CmdGate(e *Env, args []string) error {
	id := ""
	model := defaultGateModel
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--model":
			if i+1 >= len(args) {
				return usageError("--model needs M")
			}
			model = args[i+1]
			i++
		case "-h", "--help":
			printGateUsage()
			os.Exit(2)
		case "--":
		default:
			if strings.HasPrefix(args[i], "-") {
				return usageError("unknown flag %s", args[i])
			}
			if id != "" {
				return usageError("gate takes one ID")
			}
			id = args[i]
		}
	}
	if id == "" {
		return usageError("gate needs ID")
	}
	if err := validateJobID(id); err != nil {
		return err
	}
	if err := requireNoCTL("model", model); err != nil {
		return err
	}
	if err := requireBR(); err != nil {
		return err
	}
	rubric := e.GateRubric()
	if _, err := os.Stat(rubric); err != nil {
		return failError("missing gate rubric: %s", rubric)
	}
	tmpd, err := os.MkdirTemp("", "cp-gate.*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmpd)
	artifactBody, err := artifactGet(e, id)
	if err != nil {
		if ee, ok := err.(*exitError); ok && strings.Contains(ee.msg, "no artifact:v1") {
			return failError("no artifact on %s — cannot gate", id)
		}
		return failError("cannot extract artifact for %s", id)
	}
	rubricData, _ := os.ReadFile(rubric)
	prompt := string(rubricData) + "\n" + artifactBody
	promptFile := filepath.Join(tmpd, "prompt")
	if err := os.WriteFile(promptFile, []byte(prompt), 0o644); err != nil {
		return err
	}
	attempt, priorRevise, priorOp, err := gatePriorState(e, id)
	if err != nil {
		return failError("cannot list comments for %s", id)
	}
	out1 := filepath.Join(tmpd, "out1")
	_ = runGateReviewer(e, promptFile, model, out1)
	parsed, perr := parseGateVerdict(readFileOrEmpty(out1))
	if perr != nil {
		out2 := filepath.Join(tmpd, "out2")
		_ = runGateReviewer(e, promptFile, model, out2)
		parsed, perr = parseGateVerdict(readFileOrEmpty(out2))
	}
	if perr != nil {
		if priorOp == 1 {
			parsed = &gateParsed{
				Verdict: "escalate", Cause: "operational_persistent",
				Reasons: []string{"reviewer model cannot meet parse contract (prior operational escalate)"},
				Flags:   map[string]string{"destructive_scope": "no", "scope_growth": "no", "blocking_unknowns": "no"},
			}
		} else {
			parsed = &gateParsed{
				Verdict: "escalate", Cause: "operational",
				Reasons: []string{"reviewer output unparseable after one retry"},
				Flags:   map[string]string{"destructive_scope": "no", "scope_growth": "no", "blocking_unknowns": "no"},
			}
		}
	}
	commentFile := filepath.Join(tmpd, "comment")
	jsonFile := filepath.Join(tmpd, "result.json")
	verdict, err := applyGatePolicy(parsed, attempt, id, priorRevise, commentFile, jsonFile)
	if err != nil {
		return failError("cannot apply gate policy for %s", id)
	}
	if err := brCommentsAdd(e, id, commentFile); err != nil {
		return failError("br comments add failed for %s", id)
	}
	data, _ := os.ReadFile(jsonFile)
	fmt.Print(string(data))
	gateExit(verdict)
	return nil
}

func readFileOrEmpty(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}
