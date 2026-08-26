package cp

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
)

var phaseGlyph = map[string]string{
	"working": "dot", "waiting": "hollow", "held": "ring", "stalled": "cross",
	"blocked": "block", "done": "check", "ghost": "warn", "orphaned": "warn", "untracked": "dash",
}

func statusBranchMap(e *Env, whoJSON string) (string, error) {
	var who []whoRow
	if err := json.Unmarshal([]byte(whoJSON), &who); err != nil {
		return "{}", err
	}
	seen := map[string]bool{}
	var cwds []string
	for _, p := range who {
		if p.CWD != "" && !seen[p.CWD] {
			seen[p.CWD] = true
			cwds = append(cwds, p.CWD)
		}
	}
	m := map[string]string{}
	for _, cwd := range cwds {
		if st, err := os.Stat(cwd); err != nil || !st.IsDir() {
			continue
		}
		branch, _ := gitOutput(cwd, "symbolic-ref", "--quiet", "--short", "HEAD")
		if branch == "" {
			branch, _ = gitOutput(cwd, "branch", "--show-current")
		}
		if branch != "" {
			m[cwd] = branch
		}
	}
	b, err := json.Marshal(m)
	return string(b), err
}

func statusCandidateClosedIDs(jobsJSON, brOpenJSON, branchesJSON string) ([]string, error) {
	var jobs []JobRow
	var brOpen []brIssue
	var branches map[string]string
	json.Unmarshal([]byte(jobsJSON), &jobs)
	json.Unmarshal([]byte(brOpenJSON), &brOpen)
	json.Unmarshal([]byte(branchesJSON), &branches)
	openIDs := map[string]bool{}
	for _, r := range brOpen {
		openIDs[r.ID] = true
	}
	cand := map[string]bool{}
	for _, j := range jobs {
		if j.Job != "" && !openIDs[j.Job] {
			cand[j.Job] = true
		}
	}
	for _, b := range branches {
		if b != "" && !openIDs[b] {
			cand[b] = true
		}
	}
	var out []string
	for c := range cand {
		out = append(out, c)
	}
	sort.Strings(out)
	return out, nil
}

func statusAssemble(whoJSON, brokerJSON, jobsJSON, brOpenJSON, brClosedJSON, branchesJSON, generatedAt, home string, stallSec int, originFilter, brBlockedJSON string) (string, error) {
	var who []whoRow
	var broker map[string]any
	var jobs []JobRow
	var brOpen, brClosed []brIssue
	var branches map[string]string
	var brBlocked []map[string]any
	json.Unmarshal([]byte(whoJSON), &who)
	json.Unmarshal([]byte(brokerJSON), &broker)
	json.Unmarshal([]byte(jobsJSON), &jobs)
	json.Unmarshal([]byte(brOpenJSON), &brOpen)
	json.Unmarshal([]byte(brClosedJSON), &brClosed)
	json.Unmarshal([]byte(branchesJSON), &branches)
	if brBlockedJSON != "" && brBlockedJSON != "[]" {
		json.Unmarshal([]byte(brBlockedJSON), &brBlocked)
	}

	issues := map[string]brIssue{}
	for _, r := range brOpen {
		issues[r.ID] = r
	}
	for _, r := range brClosed {
		if _, ok := issues[r.ID]; !ok {
			issues[r.ID] = r
		}
	}
	jobsByWorker := map[string]JobRow{}
	jobsByWorktree := map[string]JobRow{}
	jobsByID := map[string]JobRow{}
	for _, j := range jobs {
		jobsByID[j.Job] = j
		if j.Worker != "" {
			jobsByWorker[j.Worker] = j
		}
		if j.Worktree != "" {
			jobsByWorktree[j.Worktree] = j
		}
	}

	type node map[string]any
	nodes := []node{}
	claimed := map[string]bool{}
	var rootID string

	for _, p := range who {
		name := p.Name
		role := "worker"
		if p.Parent == nil {
			role = "orchestrator"
			if rootID == "" {
				rootID = name
			}
		}
		paneState := normalizePaneState(p.State)
		cwd := p.CWD
		var bid, joinedVia, branch string
		var issue *brIssue
		var job *JobRow

		if cand, ok := jobsByWorker[name]; ok {
			if iss, ok2 := issues[cand.Job]; ok2 {
				j := cand
				job = &j
				bid = cand.Job
				joinedVia = "jobs.worker"
				issue = &iss
			}
		}
		if issue == nil && cwd != "" {
			if cand, ok := jobsByWorktree[cwd]; ok {
				if iss, ok2 := issues[cand.Job]; ok2 {
					j := cand
					job = &j
					bid = cand.Job
					joinedVia = "jobs.worktree"
					issue = &iss
				}
			}
		}
		if job != nil {
			branch = job.Branch
		}
		if issue == nil && cwd != "" {
			if brCand, ok := branches[cwd]; ok {
				if iss, ok2 := issues[brCand]; ok2 {
					bid = brCand
					joinedVia = "branch"
					issue = &iss
					branch = brCand
				}
			}
		}
		var brStatus, title any
		var labels []string
		if issue != nil {
			brStatus = normalizeBRStatus(fmt.Sprint(issue.Status))
			title = issue.Title
			labels = issue.Labels
		}
		projectVal := labelValueStr(labels, "project:")
		if projectVal == "" {
			projectVal = basenameStr(cwd)
		}
		ts, timeSource := resolveTimestamp(job, issue)
		phase := derivePhase(role, paneState, brStatus)
		if phase == "waiting" && isHeld(paneState, brStatus, job) {
			phase = "held"
		} else if phase == "waiting" && isStalled(paneState, brStatus, job, generatedAt, stallSec) {
			phase = "stalled"
		}
		if bid != "" {
			claimed[bid] = true
		}
		n := node{
			"id": name, "alias": name, "role": role, "cli": p.Kind,
			"pane": p.Pane, "session": p.Session, "pane_state": paneState,
			"drawing": false, "br_id": nilIfEmpty(bid), "br_status": brStatus,
			"phase": phase, "glyph": phaseGlyph[phase], "title": title,
			"project": projectVal, "cwd": cwd, "branch": nilIfEmpty(branch),
			"kind": labelValue(labels, "kind:"), "delivery": labelValue(labels, "delivery:"),
			"timestamp": ts, "time_source": timeSource, "joined_via": nilIfEmpty(joinedVia),
			"_pane_raw": p.Pane,
		}
		nodes = append(nodes, n)
	}

	for iid, iss := range issues {
		if fmt.Sprint(iss.Status) != "in_progress" || claimed[iid] {
			continue
		}
		job := jobsByID[iid]
		worker := iid
		var cwd, branch string
		if job.Job != "" {
			worker = job.Worker
			cwd = job.Worktree
			branch = job.Branch
		}
		ts, timeSource := resolveTimestamp(&job, &iss)
		nodes = append(nodes, node{
			"id": worker, "alias": worker, "role": "worker", "cli": nil,
			"pane": nil, "pane_state": "gone", "drawing": false,
			"br_id": iid, "br_status": "in_progress", "phase": "orphaned",
			"glyph": phaseGlyph["orphaned"], "title": iss.Title,
			"project": labelValue(iss.Labels, "project:"), "cwd": cwd,
			"branch": coalesce(branch, iid), "kind": labelValue(iss.Labels, "kind:"),
			"delivery": labelValue(iss.Labels, "delivery:"),
			"timestamp": ts, "time_source": timeSource, "joined_via": nil,
			"_pane_raw": nil,
		})
	}

	paneToAlias := map[string]string{}
	for _, n := range nodes {
		if raw, ok := n["_pane_raw"]; ok && raw != nil {
			paneToAlias[fmt.Sprint(raw)] = fmt.Sprint(n["alias"])
		}
	}
	rawDrawing, _ := broker["drawing"].([]any)
	drawingSet := map[string]bool{}
	var resolvedDrawing []string
	for _, pid := range rawDrawing {
		s := fmt.Sprint(pid)
		drawingSet[s] = true
		resolvedDrawing = append(resolvedDrawing, paneToAlias[s])
		if _, ok := paneToAlias[s]; !ok {
			resolvedDrawing[len(resolvedDrawing)-1] = s
		}
	}
	for _, n := range nodes {
		raw := n["_pane_raw"]
		n["drawing"] = raw != nil && drawingSet[fmt.Sprint(raw)]
		delete(n, "_pane_raw")
	}

	brokerOut := map[string]any{"ok": false}
	if broker != nil {
		if okVal, _ := broker["ok"].(bool); okVal {
			brokerOut = map[string]any{
				"ok":      true,
				"pid":     broker["pid"],
				"queued":  brokerCounter(broker["queued"]),
				"done":    brokerCounter(broker["done"]),
				"failed":  brokerCounter(broker["failed"]),
				"socket":  broker["socket"],
				"drawing": resolvedDrawing,
			}
		}
	}
	if !brokerOut["ok"].(bool) {
		brokerOut = map[string]any{"ok": false}
	}

	nodeIDs := map[string]bool{}
	for _, n := range nodes {
		nodeIDs[fmt.Sprint(n["id"])] = true
	}
	edges := []map[string]string{}
	for _, p := range who {
		parent := fmt.Sprint(p.Parent)
		if p.Parent != nil && nodeIDs[parent] && nodeIDs[p.Name] {
			edges = append(edges, map[string]string{"from": parent, "to": p.Name, "source": "muxa.parent"})
		}
	}
	if rootID != "" && nodeIDs[rootID] {
		for _, n := range nodes {
			if n["phase"] == "orphaned" {
				edges = append(edges, map[string]string{"from": rootID, "to": fmt.Sprint(n["id"]), "source": "inferred"})
			}
		}
	}

	if originFilter != "" {
		jobOrigin := map[string]string{}
		for _, j := range jobs {
			if j.Origin != "" {
				jobOrigin[j.Job] = j.Origin
			}
		}
		allowed := map[string]bool{}
		for jid, orig := range jobOrigin {
			if orig == originFilter {
				allowed[jid] = true
			}
		}
		blockedMap := map[string][]any{}
		for _, item := range brBlocked {
			bid, _ := item["id"].(string)
			if bid != "" {
				bb, _ := item["blocked_by"].([]any)
				blockedMap[bid] = bb
			}
		}
		blockerEntries := func(blockerIDs []any) []map[string]any {
			var out []map[string]any
			for _, b := range blockerIDs {
				bid := fmt.Sprint(b)
				if jobOrigin[bid] == originFilter {
					iss := issues[bid]
					out = append(out, map[string]any{"id": bid, "title": iss.Title})
				} else {
					out = append(out, map[string]any{"id": nil, "title": nil})
				}
			}
			return out
		}
		var filtered []node
		for _, n := range nodes {
			brID, _ := n["br_id"].(string)
			if allowed[brID] {
				filtered = append(filtered, n)
			}
		}
		nodes = filtered
		present := map[string]bool{}
		for _, n := range nodes {
			if brID, ok := n["br_id"].(string); ok {
				present[brID] = true
			}
		}
		for bid := range allowed {
			entries := blockerEntries(blockedMap[bid])
			if _, ok := blockedMap[bid]; !ok {
				continue
			}
			if present[bid] {
				for i := range nodes {
					if nodes[i]["br_id"] == bid {
						nodes[i]["phase"] = "blocked"
						nodes[i]["glyph"] = phaseGlyph["blocked"]
						nodes[i]["blocked_by"] = entries
						break
					}
				}
			} else {
				issue := issues[bid]
				job := jobsByID[bid]
				worker := bid
				var cwd string
				if job.Job != "" {
					worker = job.Worker
					cwd = job.Worktree
				}
				ts, timeSource := resolveTimestamp(&job, &issue)
				nodes = append(nodes, node{
					"id": worker, "alias": worker, "role": "worker", "cli": nil,
					"pane": nil, "pane_state": "gone", "drawing": false,
					"br_id": bid, "br_status": normalizeBRStatus(fmt.Sprint(issue.Status)),
					"phase": "blocked", "glyph": phaseGlyph["blocked"],
					"title": issue.Title, "project": labelValue(issue.Labels, "project:"),
					"cwd": cwd, "branch": coalesce(job.Branch, bid),
					"kind": labelValue(issue.Labels, "kind:"), "delivery": labelValue(issue.Labels, "delivery:"),
					"timestamp": ts, "time_source": timeSource, "joined_via": nil,
					"blocked_by": entries,
				})
			}
		}
		nodeIDs = map[string]bool{}
		for _, n := range nodes {
			nodeIDs[fmt.Sprint(n["id"])] = true
		}
		var newEdges []map[string]string
		for _, e := range edges {
			if nodeIDs[e["from"]] && nodeIDs[e["to"]] {
				newEdges = append(newEdges, e)
			}
		}
		edges = newEdges
	}

	result := map[string]any{
		"v": 1, "generated_at": generatedAt, "home": home,
		"broker": brokerOut, "nodes": nodes, "edges": edges,
	}
	if originFilter != "" {
		result["origin"] = originFilter
	}
	b, err := marshalPythonJSON(result)
	return string(b), err
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func coalesce(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func labelValueStr(labels []string, prefix string) string {
	if v := labelValue(labels, prefix); v != nil {
		return fmt.Sprint(v)
	}
	return ""
}

func labelValue(labels []string, prefix string) any {
	for _, l := range labels {
		if strings.HasPrefix(l, prefix) {
			return l[len(prefix):]
		}
	}
	return nil
}

func basenameStr(cwd string) string {
	if v := basename(cwd); v != nil {
		return fmt.Sprint(v)
	}
	return ""
}

func basename(cwd string) any {
	if cwd == "" {
		return nil
	}
	cwd = strings.TrimRight(cwd, "/")
	if i := strings.LastIndex(cwd, "/"); i >= 0 {
		return cwd[i+1:]
	}
	return cwd
}

func parseTS(s string) *time.Time {
	if s == "" {
		return nil
	}
	for _, layout := range []string{"2006-01-02T15:04:05.999999999Z", "2006-01-02T15:04:05Z"} {
		if t, err := time.Parse(layout, s); err == nil {
			return &t
		}
	}
	return nil
}

func isHeld(paneState string, brStatus any, job *JobRow) bool {
	if paneState != "idle" {
		return false
	}
	bs := fmt.Sprint(brStatus)
	if bs != "open" && bs != "in_progress" {
		return false
	}
	return job != nil && job.ReportedAt != ""
}

func isStalled(paneState string, brStatus any, job *JobRow, generatedAt string, stallSec int) bool {
	if paneState != "idle" {
		return false
	}
	bs := fmt.Sprint(brStatus)
	if bs != "open" && bs != "in_progress" {
		return false
	}
	if job == nil || job.DispatchedAt == "" || job.ReportedAt != "" {
		return false
	}
	d := parseTS(job.DispatchedAt)
	now := parseTS(generatedAt)
	if d == nil || now == nil {
		return false
	}
	return now.Sub(*d).Seconds() > float64(stallSec)
}

func normalizePaneState(state string) string {
	switch state {
	case "busy", "idle", "ghost":
		return state
	default:
		return "ghost"
	}
}

func normalizeBRStatus(status string) any {
	switch status {
	case "open", "in_progress", "closed":
		return status
	default:
		return nil
	}
}

func derivePhase(role, paneState string, brStatus any) string {
	bs := fmt.Sprint(brStatus)
	if role == "orchestrator" && brStatus == nil {
		if paneState == "ghost" {
			return "ghost"
		}
		if paneState == "busy" {
			return "working"
		}
		return "waiting"
	}
	if paneState == "ghost" {
		return "ghost"
	}
	if paneState == "gone" {
		if bs == "closed" {
			return "done"
		}
		return "orphaned"
	}
	if bs == "closed" {
		return "done"
	}
	if bs == "in_progress" || bs == "open" {
		if paneState == "busy" {
			return "working"
		}
		return "waiting"
	}
	return "untracked"
}

func resolveTimestamp(job *JobRow, issue *brIssue) (any, any) {
	if job != nil && job.DispatchedAt != "" {
		return job.DispatchedAt, "dispatched_at"
	}
	if issue != nil {
		return issue.UpdatedAt, "br_updated_at"
	}
	return nil, nil
}
