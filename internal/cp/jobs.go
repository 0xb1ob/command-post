package cp

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

var isoTimestamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$`)

type JobRow struct {
	Job          string `json:"job"`
	Worker       string `json:"worker"`
	Worktree     string `json:"worktree"`
	Branch       string `json:"branch"`
	DispatchedAt string `json:"dispatched_at,omitempty"`
	ReportedAt   string `json:"reported_at,omitempty"`
	Origin       string `json:"origin,omitempty"`
}

func jobsEnsure(e *Env) error {
	if err := os.MkdirAll(filepath.Dir(e.JobsFile), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(e.JobsFile); os.IsNotExist(err) {
		return os.WriteFile(e.JobsFile, []byte("#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n"), 0o644)
	}
	return nil
}

func jobsDispatchedAtNow() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05Z")
}

func parseJobRow(line string) JobRow {
	parts := strings.Split(line, "\t")
	for len(parts) < 7 {
		parts = append(parts, "")
	}
	row := JobRow{
		Job:      parts[0],
		Worker:   parts[1],
		Worktree: parts[2],
		Branch:   parts[3],
	}
	if parts[4] != "" {
		row.DispatchedAt = parts[4]
	}
	if parts[5] != "" {
		row.ReportedAt = parts[5]
	}
	if parts[6] != "" {
		row.Origin = parts[6]
	}
	healJobRow(&row)
	return row
}

func healJobRow(row *JobRow) {
	if row.ReportedAt != "" && row.Origin == "" {
		if !isoTimestamp.MatchString(row.ReportedAt) {
			row.Origin = row.ReportedAt
			row.ReportedAt = ""
		}
	}
}

func emitJobRow(row JobRow) string {
	var parts []string
	parts = append(parts, row.Job, row.Worker, row.Worktree, row.Branch)
	if row.Origin != "" {
		if row.ReportedAt != "" {
			parts = append(parts, row.DispatchedAt, row.ReportedAt, row.Origin)
		} else if row.DispatchedAt != "" {
			parts = append(parts, row.DispatchedAt, "", row.Origin)
		} else {
			parts = append(parts, "", "", row.Origin)
		}
	} else if row.ReportedAt != "" {
		parts = append(parts, row.DispatchedAt, row.ReportedAt)
	} else if row.DispatchedAt != "" {
		parts = append(parts, row.DispatchedAt)
	}
	return strings.Join(parts, "\t") + "\n"
}

func readJobRows(e *Env) ([]JobRow, error) {
	data, err := os.ReadFile(e.JobsFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var rows []JobRow
	for _, line := range splitLines(string(data)) {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		rows = append(rows, parseJobRow(line))
	}
	return rows, nil
}

func writeJobRows(e *Env, rows []JobRow) error {
	var buf strings.Builder
	buf.WriteString("#job\tworker\tworktree\tbranch\tdispatched_at\treported_at\torigin\n")
	for _, r := range rows {
		buf.WriteString(emitJobRow(r))
	}
	return os.WriteFile(e.JobsFile, []byte(buf.String()), 0o644)
}

func jobsHas(e *Env, id string) bool {
	rows, _ := readJobRows(e)
	for _, r := range rows {
		if r.Job == id {
			return true
		}
	}
	return false
}

func jobsLookup(e *Env, id string) (JobRow, bool) {
	rows, _ := readJobRows(e)
	for _, r := range rows {
		if r.Job == id {
			return r, true
		}
	}
	return JobRow{}, false
}

type runtimeKV struct {
	worker, worktree, branch, origin string
}

func parseRuntimeKV(args []string) (runtimeKV, error) {
	var kv runtimeKV
	for _, arg := range args {
		i := strings.IndexByte(arg, '=')
		if i < 0 {
			return kv, usageError("expected key=value, got %s", arg)
		}
		key, val := arg[:i], arg[i+1:]
		switch key {
		case "worker", "worktree", "branch", "origin":
			if err := requireNoCTL(key, val); err != nil {
				return kv, err
			}
		case "kind", "delivery", "status", "pr", "note":
			return kv, failError("refusing %s= — kind, delivery, status, PR URL, and note live on the br issue", key)
		default:
			return kv, usageError("unknown field %s= (want: worker, worktree, branch, origin)", key)
		}
		switch key {
		case "worker":
			kv.worker = val
		case "worktree":
			kv.worktree = val
		case "branch":
			kv.branch = val
		case "origin":
			kv.origin = val
		}
	}
	return kv, nil
}

func resolveWorktree(p string) (string, error) {
	st, err := os.Stat(p)
	if err != nil || !st.IsDir() {
		return "", failError("worktree is not a directory: %s", p)
	}
	return normalizePath(p)
}

func resolveBranch(worktree, branch string) (string, error) {
	if branch != "" {
		return branch, nil
	}
	detected, _ := gitOutput(worktree, "symbolic-ref", "--short", "HEAD")
	if detected == "" {
		detected, _ = gitOutput(worktree, "branch", "--show-current")
	}
	if detected == "" {
		return "", failError("cannot read branch from %s (pass branch=NAME)", worktree)
	}
	return detected, nil
}

func requireBRIssue(e *Env, id string) error {
	argv, err := brShowArgv(e)
	if err != nil {
		return err
	}
	args := append(append([]string{}, argv...), id)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Dir = e.Home
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

func JobsAdd(e *Env, id string, kv runtimeKV) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	if kv.worker == "" {
		return usageError("add needs worker=ALIAS")
	}
	if kv.worktree == "" {
		return usageError("add needs worktree=PATH")
	}
	if err := requireBRIssue(e, id); err != nil {
		return failError("no br issue %s — jobs are keyed by br id; create the issue first", id)
	}
	wt, err := resolveWorktree(kv.worktree)
	if err != nil {
		return err
	}
	br, err := resolveBranch(wt, kv.branch)
	if err != nil {
		return err
	}
	if err := jobsEnsure(e); err != nil {
		return err
	}
	if jobsHas(e, id) {
		return failError("job %s already mapped — use set to change worker/worktree/branch", id)
	}
	da := jobsDispatchedAtNow()
	row := JobRow{Job: id, Worker: kv.worker, Worktree: wt, Branch: br, DispatchedAt: da, Origin: kv.origin}
	f, err := os.OpenFile(e.JobsFile, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := f.WriteString(emitJobRow(row)); err != nil {
		return err
	}
	log("jobs add %s worker=%s branch=%s worktree=%s dispatched_at=%s origin=%s", id, kv.worker, br, wt, da, kv.origin)
	return nil
}

func JobsSet(e *Env, id string, kv runtimeKV) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	if kv.worker == "" && kv.worktree == "" && kv.branch == "" {
		return usageError("set needs at least one of worker=, worktree=, branch=")
	}
	if kv.worktree != "" {
		wt, err := resolveWorktree(kv.worktree)
		if err != nil {
			return err
		}
		kv.worktree = wt
		if kv.branch == "" {
			br, err := resolveBranch(wt, "")
			if err != nil {
				return err
			}
			kv.branch = br
		}
	}
	if err := jobsEnsure(e); err != nil {
		return err
	}
	rows, err := readJobRows(e)
	if err != nil {
		return err
	}
	found := false
	for i, r := range rows {
		if r.Job != id {
			continue
		}
		found = true
		if kv.worker != "" {
			r.Worker = kv.worker
		}
		if kv.worktree != "" {
			r.Worktree = kv.worktree
		}
		if kv.branch != "" {
			r.Branch = kv.branch
		}
		rows[i] = r
	log("jobs set %s worker=%s branch=%s worktree=%s", r.Job, r.Worker, r.Branch, r.Worktree)
		break
	}
	if !found {
		return failError("no runtime row for %s — add it first", id)
	}
	return writeJobRows(e, rows)
}

func JobsReported(e *Env, id string, extra []string) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	for _, arg := range extra {
		key := arg
		if i := strings.IndexByte(arg, '='); i >= 0 {
			key = arg[:i]
		}
		switch key {
		case "pr", "kind", "delivery", "status", "note":
			return failError("refusing %s — reported only stamps runtime state on the jobs row", key)
		default:
			return usageError("reported takes ID only, got %s", arg)
		}
	}
	if err := jobsEnsure(e); err != nil {
		return err
	}
	rows, err := readJobRows(e)
	if err != nil {
		return err
	}
	stamp := jobsDispatchedAtNow()
	found := false
	effective := ""
	for i, r := range rows {
		if r.Job != id {
			continue
		}
		found = true
		if r.ReportedAt == "" {
			r.ReportedAt = stamp
		}
		effective = r.ReportedAt
		rows[i] = r
		break
	}
	if !found {
		return failError("no runtime row for %s", id)
	}
	if err := writeJobRows(e, rows); err != nil {
		return err
	}
	log("jobs reported %s reported_at=%s", id, effective)
	return nil
}

func JobsDone(e *Env, id string, extra []string) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	for _, arg := range extra {
		key := arg
		if i := strings.IndexByte(arg, '='); i >= 0 {
			key = arg[:i]
		}
		switch key {
		case "pr", "kind", "delivery", "status", "note":
			return failError("refusing %s — put the PR URL on br close; jobs done only drops the runtime row", key)
		default:
			return usageError("done takes ID only, got %s", arg)
		}
	}
	if err := jobsEnsure(e); err != nil {
		return err
	}
	rows, err := readJobRows(e)
	if err != nil {
		return err
	}
	var kept []JobRow
	found := false
	for _, r := range rows {
		if r.Job == id {
			found = true
			continue
		}
		kept = append(kept, r)
	}
	if !found {
		return failError("no runtime row for %s", id)
	}
	if err := writeJobRows(e, kept); err != nil {
		return err
	}
	log("jobs done %s", id)
	return nil
}

func JobsListJSON(e *Env) ([]byte, error) {
	rows, err := readJobRows(e)
	if err != nil {
		return nil, err
	}
	out := make([]JobRow, 0, len(rows))
	for _, r := range rows {
		j := JobRow{Job: r.Job, Worker: r.Worker, Worktree: r.Worktree, Branch: r.Branch}
		if r.DispatchedAt != "" {
			j.DispatchedAt = r.DispatchedAt
		}
		if r.ReportedAt != "" {
			j.ReportedAt = r.ReportedAt
		}
		if r.Origin != "" {
			j.Origin = r.Origin
		}
		out = append(out, j)
	}
	return json.Marshal(out)
}

func JobsListTable(e *Env) error {
	fmt.Printf("%-28s %-20s %-28s %s\n", "JOB", "WORKER", "BRANCH", "WORKTREE")
	rows, err := readJobRows(e)
	if err != nil {
		return err
	}
	for _, r := range rows {
		fmt.Printf("%-28s %-20s %-28s %s\n", r.Job, r.Worker, r.Branch, r.Worktree)
	}
	return nil
}
