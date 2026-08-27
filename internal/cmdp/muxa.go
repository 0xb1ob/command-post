package cmdp

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
)

type whoRow struct {
	Name   string  `json:"name"`
	ID     any     `json:"id"`
	Parent any     `json:"parent"`
	Kind   any     `json:"kind"`
	State  string  `json:"state"`
	Pane   any     `json:"pane"`
	Session any    `json:"session"`
	CWD    string  `json:"cwd"`
}

type whoTSV struct {
	Name, State, CWD, Kind string
}

func muxaWhoJSON(e *Env) (string, error) {
	cmd, err := whoCmd()
	if err != nil {
		return "", err
	}
	out, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil {
		return "", usageError("muxa who --json failed")
	}
	return normalizeWhoFull(out)
}

func whoJSONRows(raw string) (string, error) {
	var data any
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return "", usageError("muxa who --json: not JSON (need muxa who --json; do not scrape the human table)")
	}
	rows, ok := data.([]any)
	if !ok {
		return "", usageError("muxa who --json: expected an array")
	}
	var out strings.Builder
	for _, item := range rows {
		r, ok := item.(map[string]any)
		if !ok {
			return "", usageError("muxa who --json: expected objects")
		}
		name := strField(r["name"])
		state := strField(r["state"])
		cwd := strField(r["cwd"])
		kind := strField(r["kind"])
		if state == "" {
			return "", usageError("muxa who --json: missing state")
		}
		for _, f := range []string{name, state, cwd, kind} {
			if strings.ContainsAny(f, "\t\n") {
				return "", usageError("muxa who --json: field contains a tab or newline")
			}
		}
		fmt.Fprintf(&out, "%s\t%s\t%s\t%s\n", name, state, cwd, kind)
	}
	return out.String(), nil
}

func normalizeWhoFull(raw string) (string, error) {
	var rows []map[string]any
	if err := json.Unmarshal([]byte(raw), &rows); err != nil {
		return "", usageError("muxa who --json: not JSON")
	}
	out := make([]whoRow, 0, len(rows))
	for _, r := range rows {
		name := strField(r["name"])
		state := strField(r["state"])
		if name == "" || state == "" {
			return "", usageError("muxa who --json: missing name or state")
		}
		out = append(out, whoRow{
			Name: name, ID: r["id"], Parent: r["parent"], Kind: r["kind"],
			State: state, Pane: r["pane"], Session: r["session"], CWD: strField(r["cwd"]),
		})
	}
	b, err := json.Marshal(out)
	return string(b), err
}

func strField(v any) string {
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}

func parseWhoTSV(parsed string) []whoTSV {
	var rows []whoTSV
	for _, line := range splitLines(parsed) {
		if line == "" {
			continue
		}
		parts := strings.Split(line, "\t")
		for len(parts) < 4 {
			parts = append(parts, "")
		}
		rows = append(rows, whoTSV{Name: parts[0], State: parts[1], CWD: parts[2], Kind: parts[3]})
	}
	return rows
}

func muxaWhoamiName() (string, error) {
	if self := os.Getenv("MUXA_WHOAMI"); self != "" {
		return self, nil
	}
	if err := requireMuxaBin(); err != nil {
		return "", err
	}
	out, err := runCmdCapture("muxa", "whoami")
	if err != nil || out == "" {
		return "", failError("muxa whoami is empty — register this pane (muxa hook / muxa register), then retry")
	}
	return out, nil
}

func workerInWho(e *Env, want string) (bool, error) {
	cmd, err := whoCmd()
	if err != nil {
		return false, err
	}
	out, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil {
		return false, usageError("muxa who --json failed")
	}
	parsed, err := whoJSONRows(out)
	if err != nil {
		return false, err
	}
	for _, row := range parseWhoTSV(parsed) {
		if row.Name == want {
			return true, nil
		}
	}
	return false, nil
}

func workerKind(e *Env, want string) (string, error) {
	cmd, err := whoCmd()
	if err != nil {
		return "", err
	}
	out, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil {
		return "", usageError("muxa who --json failed")
	}
	parsed, err := whoJSONRows(out)
	if err != nil {
		return "", err
	}
	for _, row := range parseWhoTSV(parsed) {
		if row.Name == want {
			return row.Kind, nil
		}
	}
	return "", nil
}

func checkOccupancy(e *Env, targets []string) error {
	norm := make([]string, 0, len(targets))
	for _, t := range targets {
		p, err := normalizePath(t)
		if err != nil {
			return err
		}
		norm = append(norm, p)
	}
	cmd, err := whoCmd()
	if err != nil {
		return err
	}
	whoOut, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil {
		return usageError("muxa who --json failed")
	}
	parsed, err := whoJSONRows(whoOut)
	if err != nil {
		return err
	}
	self := os.Getenv("MUXA_WHOAMI")
	if self == "" && os.Getenv("MUXA_WHO_CMD") == "" && lookPath("muxa") != "" {
		self, _ = runCmdCapture("muxa", "whoami")
	}
	collisions, ghostHits := 0, 0
	for _, row := range parseWhoTSV(parsed) {
		if row.CWD == "" {
			continue
		}
		resolved, _ := normalizePath(row.CWD)
		if self != "" && row.Name == self {
			continue
		}
		hit := false
		for _, t := range norm {
			if resolved == t {
				hit = true
				break
			}
		}
		if !hit {
			continue
		}
		switch row.State {
		case "idle", "busy":
			fmt.Fprintf(os.Stderr, "[cmdp] promote-not-spawn: live worker %s occupies %s\n", row.Name, resolved)
			fmt.Fprintf(os.Stderr, "[cmdp] same worktree still held → %s %s (do not muxa dispatch, do not treehouse get --lease)\n", "muxa", "send "+row.Name)
			collisions++
		case "ghost":
			fmt.Fprintf(os.Stderr, "[cmdp] occupied cwd: ghost worker %s on %s — muxa kill NAME|ID for a dead pane, or restart the CLI in that pane; do not promote, do not dispatch\n", row.Name, resolved)
			ghostHits++
		default:
			fmt.Fprintf(os.Stderr, "[cmdp] occupied cwd: worker %s (state %s) on %s — do not dispatch\n", row.Name, row.State, resolved)
			collisions++
		}
	}
	if collisions > 0 || ghostHits > 0 {
		return failError("occupancy check failed")
	}
	log("clear: no other live registered worker on the given worktree(s)")
	return nil
}

func dispatchOccupancyWarningContradiction(e *Env, stderrFile string) error {
	data, err := os.ReadFile(stderrFile)
	if err != nil {
		return nil
	}
	text := string(data)
	idx := strings.Index(text, "already has live worker ")
	if idx < 0 {
		return nil
	}
	rest := text[idx+len("already has live worker "):]
	warned := strings.Fields(rest)
	if len(warned) == 0 {
		return nil
	}
	warnedName := warned[0]
	cmd, err := whoCmd()
	if err != nil {
		return err
	}
	out, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil {
		return usageError("muxa who --json failed while checking dispatch occupancy warning")
	}
	parsed, err := whoJSONRows(out)
	if err != nil {
		return err
	}
	for _, row := range parseWhoTSV(parsed) {
		if row.Name == warnedName {
			return nil
		}
	}
	fmt.Fprintf(os.Stderr, "[cmdp] fail: muxa dispatch warns cwd already has live worker %s but muxa who --json omits that worker\n", warnedName)
	fmt.Fprintf(os.Stderr, "[cmdp] contradicting signals — roster absence is not proof the worker is dead; inspect with muxa tail %s before proceeding\n", warnedName)
	return failError("occupancy contradiction")
}

type dispatchParsed struct {
	Worker, CWD, State string
}

func parseDispatchJSON(raw string) (dispatchParsed, error) {
	var obj map[string]any
	if err := json.Unmarshal([]byte(raw), &obj); err != nil {
		return dispatchParsed{}, usageError("muxa dispatch stdout is not JSON (state=dispatched means queued, not received)")
	}
	name := strField(obj["name"])
	cwd := strField(obj["cwd"])
	state := strField(obj["state"])
	if name == "" {
		return dispatchParsed{}, failError("muxa dispatch JSON missing name")
	}
	for _, f := range []string{name, cwd, state} {
		if strings.ContainsAny(f, "\t\n") {
			return dispatchParsed{}, usageError("muxa dispatch JSON: field contains a tab or newline")
		}
	}
	return dispatchParsed{Worker: name, CWD: cwd, State: state}, nil
}

func dispatchKillOrphanPane(e *Env, dispatchStdout string, keepLease *bool) error {
	parsed, err := parseDispatchJSON(dispatchStdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "[cmdp] error: occupancy contradiction but muxa dispatch JSON is unusable — lease kept")
		*keepLease = true
		return failError("dispatch json unusable")
	}
	if parsed.Worker == "" {
		fmt.Fprintln(os.Stderr, "[cmdp] error: occupancy contradiction but muxa dispatch JSON has no worker name — lease kept")
		*keepLease = true
		return failError("no worker name")
	}
	if err := requireMuxaBin(); err != nil {
		return err
	}
	if err := runCmd("muxa", "kill", parsed.Worker); err != nil {
		fmt.Fprintf(os.Stderr, "[cmdp] error: occupancy contradiction — muxa kill %s failed; lease kept on worktree\n", parsed.Worker)
		*keepLease = true
		return err
	}
	return nil
}

func emitDispatchJSON(brID, worker, worktree, branch, state, receipt string) error {
	out := map[string]string{
		"br_id": brID, "worker": worker, "worktree": worktree,
		"branch": branch, "state": state, "receipt": receipt,
	}
	s, err := marshalPythonJSON(out)
	if err != nil {
		return err
	}
	fmt.Println(s)
	return nil
}

func muxaBrokerJSON() string {
	cmd := brokerCmd()
	out, err := runCmdCapture(cmd[0], cmd[1:]...)
	if err != nil || out == "" {
		return `{"ok": false}`
	}
	var d map[string]any
	if err := json.Unmarshal([]byte(out), &d); err != nil || d == nil {
		return `{"ok": false}`
	}
	if _, ok := d["ok"]; !ok {
		d["ok"] = true
	}
	b, _ := json.Marshal(d)
	return string(b)
}
