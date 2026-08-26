package cp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Slack thread bindings. state/threads.tsv maps an origin id (the value in the
// jobs.tsv origin column) to one Slack thread. br_id is the routing key:
// jobs.tsv gives br_id -> origin, this file gives origin -> (channel, ts).
// A job with no origin is routable nowhere and is dropped, not broadcast.

var (
	slackChannelPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{2,64}$`)
	slackTSPattern      = regexp.MustCompile(`^[0-9]{6,12}\.[0-9]{1,8}$`)
)

// originTerminal is the origin stamped on terminal dispatch. It is not a Slack
// thread and can never be bound to one.
const originTerminal = "terminal"

type ThreadRow struct {
	ID       string `json:"id"`
	Channel  string `json:"channel"`
	ThreadTS string `json:"thread_ts"`
	BoundAt  string `json:"bound_at,omitempty"`
}

func (e *Env) ThreadsDir() string { return filepath.Join(e.Home, "state", "threads") }

func threadsEnsure(e *Env) error {
	if err := os.MkdirAll(filepath.Dir(e.ThreadsFile), 0o755); err != nil {
		return err
	}
	if _, err := os.Stat(e.ThreadsFile); os.IsNotExist(err) {
		return os.WriteFile(e.ThreadsFile, []byte("#id\tchannel\tthread_ts\tbound_at\n"), 0o644)
	}
	return nil
}

func readThreadRows(e *Env) ([]ThreadRow, error) {
	data, err := os.ReadFile(e.ThreadsFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var rows []ThreadRow
	for _, line := range splitLines(string(data)) {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		for len(parts) < 4 {
			parts = append(parts, "")
		}
		rows = append(rows, ThreadRow{ID: parts[0], Channel: parts[1], ThreadTS: parts[2], BoundAt: parts[3]})
	}
	return rows, nil
}

func writeThreadRows(e *Env, rows []ThreadRow) error {
	var buf strings.Builder
	buf.WriteString("#id\tchannel\tthread_ts\tbound_at\n")
	for _, r := range rows {
		buf.WriteString(strings.Join([]string{r.ID, r.Channel, r.ThreadTS, r.BoundAt}, "\t") + "\n")
	}
	return os.WriteFile(e.ThreadsFile, []byte(buf.String()), 0o644)
}

// threadLookup resolves an origin id to its bound thread. Unbound origins are
// not an error here; every caller that would post decides fail-closed.
func threadLookup(e *Env, origin string) (ThreadRow, bool) {
	rows, _ := readThreadRows(e)
	for _, r := range rows {
		if r.ID == origin {
			return r, true
		}
	}
	return ThreadRow{}, false
}

func validateOriginID(id string) error {
	if !jobIDPattern.MatchString(id) {
		return failError("invalid origin id: %s (no whitespace)", id)
	}
	if id == originTerminal {
		return failError("origin %s is terminal dispatch, not a Slack thread — it can never be bound", originTerminal)
	}
	return nil
}

func threadsBind(e *Env, id string, kv map[string]string) error {
	if err := validateOriginID(id); err != nil {
		return err
	}
	channel, ts := kv["channel"], kv["thread_ts"]
	if channel == "" {
		return usageError("bind needs channel=ID")
	}
	if ts == "" {
		return usageError("bind needs thread_ts=TS")
	}
	if !slackChannelPattern.MatchString(channel) {
		return failError("invalid channel: %s (Slack channel id, e.g. C0123ABCDEF)", channel)
	}
	if !slackTSPattern.MatchString(ts) {
		return failError("invalid thread_ts: %s (Slack ts, e.g. 1712345678.000100)", ts)
	}
	if err := threadsEnsure(e); err != nil {
		return err
	}
	rows, err := readThreadRows(e)
	if err != nil {
		return err
	}
	for _, r := range rows {
		if r.ID == id {
			return failError("origin %s is already bound to %s/%s — unbind first", id, r.Channel, r.ThreadTS)
		}
		if r.Channel == channel && r.ThreadTS == ts {
			return failError("thread %s/%s is already bound to origin %s — one origin per thread", channel, ts, r.ID)
		}
	}
	rows = append(rows, ThreadRow{ID: id, Channel: channel, ThreadTS: ts, BoundAt: jobsDispatchedAtNow()})
	if err := writeThreadRows(e, rows); err != nil {
		return err
	}
	if err := os.MkdirAll(e.ThreadsDir(), 0o700); err != nil {
		return err
	}
	log("threads bind %s channel=%s thread_ts=%s", id, channel, ts)
	return nil
}

func threadsUnbind(e *Env, id string) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	rows, err := readThreadRows(e)
	if err != nil {
		return err
	}
	var kept []ThreadRow
	found := false
	for _, r := range rows {
		if r.ID == id {
			found = true
			continue
		}
		kept = append(kept, r)
	}
	if !found {
		return failError("no thread bound to origin %s", id)
	}
	if err := writeThreadRows(e, kept); err != nil {
		return err
	}
	log("threads unbind %s (outbound log kept at %s)", id, threadOutLog(e, id))
	return nil
}

func threadsList(e *Env, jsonOut bool) error {
	rows, err := readThreadRows(e)
	if err != nil {
		return err
	}
	if jsonOut {
		out := rows
		if out == nil {
			out = []ThreadRow{}
		}
		b, err := json.Marshal(out)
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("%-28s %-16s %-20s %s\n", "ORIGIN", "CHANNEL", "THREAD_TS", "BOUND_AT")
	for _, r := range rows {
		fmt.Printf("%-28s %-16s %-20s %s\n", r.ID, r.Channel, r.ThreadTS, r.BoundAt)
	}
	return nil
}

// --- events -----------------------------------------------------------------

// BlockerRef names a br dep blocker. Cross-origin blockers carry nil id and
// title: br ids are paired with plain-language labels by contract, so either
// field would leak the other origin's work into this thread.
type BlockerRef struct {
	ID    *string `json:"id"`
	Title *string `json:"title"`
}

type ThreadEvent struct {
	Origin    string       `json:"origin"`
	BRID      string       `json:"br_id"`
	Kind      string       `json:"kind"`
	At        string       `json:"at,omitempty"`
	Title     string       `json:"title,omitempty"`
	Branch    string       `json:"branch,omitempty"`
	Worker    string       `json:"worker,omitempty"`
	BlockedBy []BlockerRef `json:"blocked_by,omitempty"`
}

var eventKinds = []string{"dispatched", "reported", "blocked", "closed"}

func validEventKind(kind string) bool {
	for _, k := range eventKinds {
		if k == kind {
			return true
		}
	}
	return false
}

func eventKindRank(kind string) int {
	for i, k := range eventKinds {
		if k == kind {
			return i
		}
	}
	return len(eventKinds)
}

// brIssuesFor looks up the given br ids, open first then closed, so a closed
// job still renders a title. Unknown ids are simply absent from the map.
func brIssuesFor(e *Env, ids []string) (map[string]brIssue, error) {
	out := map[string]brIssue{}
	if len(ids) == 0 {
		return out, nil
	}
	openJSON, err := brListJSON(e, "--json")
	if err != nil {
		return nil, err
	}
	var open []brIssue
	json.Unmarshal([]byte(openJSON), &open)
	for _, r := range open {
		out[r.ID] = r
	}
	var missing []string
	for _, id := range ids {
		if _, ok := out[id]; !ok {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		args := []string{"-s", "closed", "--json"}
		for _, id := range missing {
			args = append(args, "--id", id)
		}
		closedJSON, err := brListJSON(e, args...)
		if err != nil {
			return nil, err
		}
		var closed []brIssue
		json.Unmarshal([]byte(closedJSON), &closed)
		for _, r := range closed {
			if _, ok := out[r.ID]; !ok {
				out[r.ID] = r
			}
		}
	}
	return out, nil
}

// threadEvents derives this origin's event stream from the ledger. It is a
// lookup, not a judgement: only rows whose origin equals this one are read, so
// another origin's work cannot appear. Returns the number of ledger rows that
// carry no origin at all — those are routable nowhere.
func threadEvents(e *Env, origin string) ([]ThreadEvent, int, error) {
	rows, err := readJobRows(e)
	if err != nil {
		return nil, 0, err
	}
	originOf := map[string]string{}
	noOrigin := 0
	var mine []JobRow
	for _, r := range rows {
		if r.Origin == "" {
			noOrigin++
			continue
		}
		originOf[r.Job] = r.Origin
		if r.Origin == origin {
			mine = append(mine, r)
		}
	}
	if len(mine) == 0 {
		return nil, noOrigin, nil
	}
	var ids []string
	for _, r := range mine {
		ids = append(ids, r.Job)
	}
	issues, err := brIssuesFor(e, ids)
	if err != nil {
		return nil, noOrigin, err
	}
	blockedJSON, err := brBlockedJSON(e)
	if err != nil {
		return nil, noOrigin, err
	}
	var blocked []struct {
		ID        string   `json:"id"`
		BlockedBy []string `json:"blocked_by"`
	}
	json.Unmarshal([]byte(blockedJSON), &blocked)
	blockedBy := map[string][]string{}
	for _, b := range blocked {
		blockedBy[b.ID] = b.BlockedBy
	}

	var events []ThreadEvent
	for _, r := range mine {
		iss := issues[r.Job]
		title := ""
		if iss.Title != nil {
			title = fmt.Sprint(iss.Title)
		}
		base := ThreadEvent{Origin: origin, BRID: r.Job, Title: title, Branch: r.Branch, Worker: r.Worker}
		if r.DispatchedAt != "" {
			ev := base
			ev.Kind, ev.At = "dispatched", r.DispatchedAt
			events = append(events, ev)
		}
		if r.ReportedAt != "" {
			ev := base
			ev.Kind, ev.At = "reported", r.ReportedAt
			events = append(events, ev)
		}
		updated := ""
		if iss.UpdatedAt != nil {
			updated = fmt.Sprint(iss.UpdatedAt)
		}
		if bb, ok := blockedBy[r.Job]; ok {
			ev := base
			ev.Kind, ev.At = "blocked", updated
			ev.BlockedBy = redactBlockers(bb, origin, originOf, issues)
			events = append(events, ev)
		}
		if iss.Status != nil && fmt.Sprint(iss.Status) == "closed" {
			ev := base
			ev.Kind, ev.At = "closed", updated
			events = append(events, ev)
		}
	}
	sort.SliceStable(events, func(i, j int) bool {
		if events[i].At != events[j].At {
			return events[i].At < events[j].At
		}
		if events[i].BRID != events[j].BRID {
			return events[i].BRID < events[j].BRID
		}
		return eventKindRank(events[i].Kind) < eventKindRank(events[j].Kind)
	})
	return events, noOrigin, nil
}

// redactBlockers keeps id and title only for blockers this origin already owns.
// Everything else becomes an anonymous blocker: a thread seeing "blocked" with
// no named reason is intentional until the blocker shares its origin or closes.
func redactBlockers(blockerIDs []string, origin string, originOf map[string]string, issues map[string]brIssue) []BlockerRef {
	out := make([]BlockerRef, 0, len(blockerIDs))
	for _, bid := range blockerIDs {
		if originOf[bid] == origin && origin != "" {
			id := bid
			title := ""
			if iss, ok := issues[bid]; ok && iss.Title != nil {
				title = fmt.Sprint(iss.Title)
			}
			t := title
			out = append(out, BlockerRef{ID: &id, Title: &t})
			continue
		}
		out = append(out, BlockerRef{})
	}
	return out
}

// eventForKind picks one derived event for a br id, so the relay renders ledger
// truth rather than caller-supplied prose.
func eventForKind(e *Env, brID, kind string) (ThreadEvent, error) {
	row, ok := jobsLookup(e, brID)
	if !ok {
		return ThreadEvent{}, failError("no runtime row for %s — posting nowhere", brID)
	}
	if row.Origin == "" {
		return ThreadEvent{}, failError("job %s has no origin — posting nowhere", brID)
	}
	if row.Origin == originTerminal {
		return ThreadEvent{}, failError("job %s was dispatched from the terminal (origin=%s) — posting nowhere", brID, originTerminal)
	}
	// A hand-edited ledger row must not become a path or a wildcard.
	if !jobIDPattern.MatchString(row.Origin) {
		return ThreadEvent{}, failError("job %s has a malformed origin %q — posting nowhere", brID, row.Origin)
	}
	events, _, err := threadEvents(e, row.Origin)
	if err != nil {
		return ThreadEvent{}, err
	}
	for i := len(events) - 1; i >= 0; i-- {
		if events[i].BRID == brID && events[i].Kind == kind {
			return events[i], nil
		}
	}
	return ThreadEvent{}, failError("job %s has no %s event in the ledger — nothing to post", brID, kind)
}

func threadsEvents(e *Env, origin string, jsonOut bool) error {
	if err := validateOriginID(origin); err != nil {
		return err
	}
	events, noOrigin, err := threadEvents(e, origin)
	if err != nil {
		return err
	}
	if noOrigin > 0 {
		log("threads events: %d ledger row(s) carry no origin — dropped, routable nowhere", noOrigin)
	}
	if jsonOut {
		if events == nil {
			events = []ThreadEvent{}
		}
		b, err := json.Marshal(events)
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("%-22s %-28s %-12s %s\n", "AT", "JOB", "KIND", "WHAT")
	for _, ev := range events {
		fmt.Printf("%-22s %-28s %-12s %s\n", dashIfEmpty(ev.At), ev.BRID, ev.Kind, dashIfEmpty(ev.Title))
	}
	return nil
}

func dashIfEmpty(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

func parseKV(args []string, allowed ...string) (map[string]string, error) {
	kv := map[string]string{}
	for _, arg := range args {
		i := strings.IndexByte(arg, '=')
		if i < 0 {
			return nil, usageError("expected key=value, got %s", arg)
		}
		key, val := arg[:i], arg[i+1:]
		ok := false
		for _, a := range allowed {
			if a == key {
				ok = true
			}
		}
		if !ok {
			return nil, usageError("unknown field %s= (want: %s)", key, strings.Join(allowed, ", "))
		}
		if err := requireNoCTL(key, val); err != nil {
			return nil, err
		}
		kv[key] = val
	}
	return kv, nil
}

func CmdThreads(e *Env, args []string) error {
	if len(args) == 0 {
		return usageError("missing bind|unbind|list|events|status|log")
	}
	switch args[0] {
	case "bind":
		if len(args) < 2 {
			return usageError("bind needs ID")
		}
		kv, err := parseKV(args[2:], "channel", "thread_ts")
		if err != nil {
			return err
		}
		return threadsBind(e, args[1], kv)
	case "unbind":
		if len(args) != 2 {
			return usageError("unbind takes ID only")
		}
		return threadsUnbind(e, args[1])
	case "list":
		jsonOut := false
		for _, a := range args[1:] {
			switch a {
			case "--json":
				jsonOut = true
			case "-h", "--help":
				printThreadsUsage()
			default:
				return usageError("unknown list flag %s", a)
			}
		}
		return threadsList(e, jsonOut)
	case "events":
		if len(args) < 2 {
			return usageError("events needs ID")
		}
		jsonOut := false
		for _, a := range args[2:] {
			switch a {
			case "--json":
				jsonOut = true
			default:
				return usageError("unknown events flag %s", a)
			}
		}
		return threadsEvents(e, args[1], jsonOut)
	case "status":
		if len(args) < 2 {
			return usageError("status needs ID")
		}
		if err := validateOriginID(args[1]); err != nil {
			return err
		}
		if _, ok := threadLookup(e, args[1]); !ok {
			return failError("no thread bound to origin %s — bind it first (bin/cp threads bind)", args[1])
		}
		return CmdStatus(e, append([]string{"--origin", args[1]}, args[2:]...))
	case "log":
		if len(args) != 2 {
			return usageError("log takes ID only")
		}
		if err := validateOriginID(args[1]); err != nil {
			return err
		}
		fmt.Println(threadOutLog(e, args[1]))
		return nil
	case "-h", "--help":
		printThreadsUsage()
	default:
		return usageError("unknown threads command %s (want: bind, unbind, list, events, status, log)", args[0])
	}
	return nil
}
