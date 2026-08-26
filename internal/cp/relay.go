package cp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// The relay is the only thing in this repo that writes to Slack. The parent
// never does. What crosses into a thread is a templated, origin-keyed job event
// rendered from the ledger — never a parent turn, never a STATUS BLOCK.
//
// Fail closed everywhere: no origin, no binding, no tokens, no post.

const slackAPIDefault = "https://slack.com/api"

// exitNotConfigured is returned when Slack credentials are absent. It is not a
// failure of the caller: this repo ships without an installed Slack app, and
// every relay path must be a no-op until the operator installs one.
const exitNotConfigured = 3

// Default event templates. $CP_HOME/templates/thread-events.tsv overrides them
// per home — that is the tracked templates/thread-events.tsv when the home is
// this clone. The built-ins keep the relay working from any home.
var defaultEventTemplates = map[string]string{
	"dispatched": "Job {{br_id}} dispatched — {{title}} (branch {{branch}}, worker {{worker}}).",
	"reported":   "Job {{br_id}} reported back — {{title}}. Review is with the operator.",
	"blocked":    "Job {{br_id}} is blocked — {{title}}. Waiting on {{blocked_on}}.",
	"closed":     "Job {{br_id}} closed — {{title}}.",
}

var templatePlaceholder = regexp.MustCompile(`\{\{[^}]+\}\}`)

func (e *Env) ThreadEventsTSV() string {
	if v := os.Getenv("CP_THREAD_EVENTS_TSV"); v != "" {
		return v
	}
	return filepath.Join(e.Home, "templates", "thread-events.tsv")
}

func (e *Env) SlackTokensFile() string {
	if v := os.Getenv("CP_SLACK_TOKENS"); v != "" {
		return v
	}
	return filepath.Join(e.Home, "state", "slack", "tokens.env")
}

func threadOutLog(e *Env, origin string) string {
	return filepath.Join(e.ThreadsDir(), origin+".out.log")
}

// threadDropLog records every event the relay refused to post. A drop is the
// fail-closed outcome, so it must still be auditable locally.
func threadDropLog(e *Env) string {
	return filepath.Join(e.ThreadsDir(), "dropped.log")
}

func appendJSONL(path string, rec map[string]any) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	b, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = f.Write(append(b, '\n'))
	return err
}

func relayDrop(e *Env, brID, kind, origin, reason string) {
	rec := map[string]any{
		"at": jobsDispatchedAtNow(), "br_id": brID, "kind": kind, "reason": reason,
	}
	if origin != "" {
		rec["origin"] = origin
	}
	if err := appendJSONL(threadDropLog(e), rec); err != nil {
		log("warning: cannot write drop log %s (%v)", threadDropLog(e), err)
	}
}

// --- templates ---------------------------------------------------------------

func loadEventTemplates(e *Env) (map[string]string, error) {
	out := map[string]string{}
	for k, v := range defaultEventTemplates {
		out[k] = v
	}
	path := e.ThreadEventsTSV()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return out, nil
		}
		return nil, err
	}
	for _, line := range splitLines(string(data)) {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, "\t", 2)
		if len(parts) != 2 || parts[1] == "" {
			return nil, failError("%s: expected kind<TAB>template, got %q", path, line)
		}
		if !validEventKind(parts[0]) {
			return nil, failError("%s: unknown event kind %s (want: %s)", path, parts[0], strings.Join(eventKinds, ", "))
		}
		out[parts[0]] = parts[1]
	}
	return out, nil
}

// renderBlockedOn keeps redaction visible at the render site: a blocker with a
// nil id is another origin's job and gets a plain-language placeholder only.
func renderBlockedOn(refs []BlockerRef) string {
	if len(refs) == 0 {
		return "another job"
	}
	var parts []string
	anon := 0
	for _, r := range refs {
		if r.ID == nil {
			anon++
			continue
		}
		if r.Title != nil && *r.Title != "" {
			parts = append(parts, fmt.Sprintf("%s (%s)", *r.ID, *r.Title))
		} else {
			parts = append(parts, *r.ID)
		}
	}
	if anon == 1 {
		parts = append(parts, "another job")
	} else if anon > 1 {
		parts = append(parts, fmt.Sprintf("%d other jobs", anon))
	}
	return strings.Join(parts, " and ")
}

func renderEvent(templates map[string]string, ev ThreadEvent) (string, error) {
	tpl, ok := templates[ev.Kind]
	if !ok {
		return "", failError("no template for event kind %s", ev.Kind)
	}
	repl := map[string]string{
		"{{br_id}}":      ev.BRID,
		"{{title}}":      coalesce(ev.Title, "(untitled)"),
		"{{branch}}":     coalesce(ev.Branch, "-"),
		"{{worker}}":     coalesce(ev.Worker, "-"),
		"{{blocked_on}}": renderBlockedOn(ev.BlockedBy),
		"{{kind}}":       ev.Kind,
		"{{at}}":         ev.At,
	}
	text := tpl
	for k, v := range repl {
		text = strings.ReplaceAll(text, k, v)
	}
	if left := templatePlaceholder.FindString(text); left != "" {
		return "", failError("template for %s leaves %s unsubstituted (want: br_id, title, branch, worker, blocked_on, kind, at)", ev.Kind, left)
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return "", failError("template for %s rendered empty", ev.Kind)
	}
	return text, nil
}

// --- credentials -------------------------------------------------------------

type slackConfig struct {
	BotToken string
	AppToken string
	Path     string
}

// loadSlackConfig reads the documented token file. Absent file = not
// configured (exit 3, no posts). Present but unsafe or malformed = a refusal:
// a half-configured relay must not post.
func loadSlackConfig(e *Env) (*slackConfig, error) {
	path := e.SlackTokensFile()
	st, err := os.Stat(path)
	if err != nil {
		return nil, nil
	}
	if st.IsDir() {
		return nil, failError("%s is a directory — expected a token file", path)
	}
	if st.Mode().Perm()&0o077 != 0 {
		return nil, failError("%s is group/world readable (mode %04o) — run: chmod 600 %s", path, st.Mode().Perm(), path)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	cfg := &slackConfig{Path: path}
	for _, line := range splitLines(string(data)) {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		i := strings.IndexByte(line, '=')
		if i < 0 {
			continue
		}
		key := strings.TrimSpace(line[:i])
		val := strings.Trim(strings.TrimSpace(line[i+1:]), `"'`)
		switch key {
		case "SLACK_BOT_TOKEN":
			cfg.BotToken = val
		case "SLACK_APP_TOKEN":
			cfg.AppToken = val
		}
	}
	if cfg.BotToken == "" {
		return nil, failError("%s has no SLACK_BOT_TOKEN — see docs/slack-install.md", path)
	}
	if !strings.HasPrefix(cfg.BotToken, "xoxb-") {
		return nil, failError("%s: SLACK_BOT_TOKEN is not a bot token (want xoxb-…) — see docs/slack-install.md", path)
	}
	return cfg, nil
}

// --- posting -----------------------------------------------------------------

func slackAPIBase() string {
	if v := os.Getenv("CP_SLACK_API_BASE"); v != "" {
		return strings.TrimRight(v, "/")
	}
	return slackAPIDefault
}

func slackPostMessage(cfg *slackConfig, channel, threadTS, text string) error {
	body, err := json.Marshal(map[string]any{
		"channel": channel, "thread_ts": threadTS, "text": text,
	})
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", slackAPIBase()+"/chat.postMessage", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	req.Header.Set("Authorization", "Bearer "+cfg.BotToken)
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return failError("slack chat.postMessage failed: %v", err)
	}
	defer resp.Body.Close()
	var out struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	dec := json.NewDecoder(resp.Body)
	if err := dec.Decode(&out); err != nil {
		return failError("slack chat.postMessage: unreadable response (HTTP %d)", resp.StatusCode)
	}
	if !out.OK {
		return failError("slack chat.postMessage refused: %s (HTTP %d)", coalesce(out.Error, "unknown_error"), resp.StatusCode)
	}
	return nil
}

// --- commands ----------------------------------------------------------------

type relayResolved struct {
	Event ThreadEvent
	Row   ThreadRow
	Text  string
}

// relayResolve is the whole isolation mechanism in one place: br id -> origin
// (jobs.tsv) -> thread (threads.tsv) -> templated text. Any missing link is a
// refusal, logged locally, posted nowhere.
func relayResolve(e *Env, brID, kind string) (*relayResolved, error) {
	if err := validateJobID(brID); err != nil {
		return nil, err
	}
	if !validEventKind(kind) {
		return nil, usageError("unknown --kind %s (want: %s)", kind, strings.Join(eventKinds, ", "))
	}
	ev, err := eventForKind(e, brID, kind)
	if err != nil {
		// The refusal reason is ledger-local (br id, origin, kind) and never
		// carries another origin's text, so it is safe to keep.
		relayDrop(e, brID, kind, "", err.Error())
		return nil, err
	}
	row, ok := threadLookup(e, ev.Origin)
	if !ok {
		relayDrop(e, brID, kind, ev.Origin, "origin not bound to a thread")
		return nil, failError("origin %s is not bound to a thread — posting nowhere (bin/cp threads bind)", ev.Origin)
	}
	templates, err := loadEventTemplates(e)
	if err != nil {
		return nil, err
	}
	text, err := renderEvent(templates, ev)
	if err != nil {
		return nil, err
	}
	return &relayResolved{Event: ev, Row: row, Text: text}, nil
}

func relayRender(e *Env, brID, kind string, jsonOut bool) error {
	r, err := relayResolve(e, brID, kind)
	if err != nil {
		return err
	}
	if jsonOut {
		b, err := json.Marshal(map[string]any{
			"origin": r.Event.Origin, "channel": r.Row.Channel, "thread_ts": r.Row.ThreadTS,
			"br_id": r.Event.BRID, "kind": r.Event.Kind, "text": r.Text,
		})
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Println(r.Text)
	return nil
}

func relayPost(e *Env, brID, kind string) error {
	r, err := relayResolve(e, brID, kind)
	if err != nil {
		return err
	}
	cfg, err := loadSlackConfig(e)
	if err != nil {
		return err
	}
	if cfg == nil {
		relayDrop(e, brID, kind, r.Event.Origin, "not configured")
		return &exitError{code: exitNotConfigured, msg: fmt.Sprintf(
			"slack: not configured (no %s) — nothing posted; see docs/slack-install.md", e.SlackTokensFile())}
	}
	if err := slackPostMessage(cfg, r.Row.Channel, r.Row.ThreadTS, r.Text); err != nil {
		relayDrop(e, brID, kind, r.Event.Origin, "slack api error")
		return err
	}
	// Outbound only. Inbound Slack messages are never stored; our own speech is
	// ours to keep, and this log is how the operator audits a suspected leak.
	if err := appendJSONL(threadOutLog(e, r.Event.Origin), map[string]any{
		"at": jobsDispatchedAtNow(), "origin": r.Event.Origin,
		"channel": r.Row.Channel, "thread_ts": r.Row.ThreadTS,
		"br_id": r.Event.BRID, "kind": r.Event.Kind, "text": r.Text,
	}); err != nil {
		return err
	}
	log("relay post %s %s -> %s (%s/%s)", brID, kind, r.Event.Origin, r.Row.Channel, r.Row.ThreadTS)
	return nil
}

func relayStatus(e *Env, jsonOut bool) error {
	cfg, cfgErr := loadSlackConfig(e)
	rows, _ := readThreadRows(e)
	state, detail := "not configured", ""
	switch {
	case cfgErr != nil:
		state, detail = "refused", cfgErr.Error()
	case cfg != nil:
		state = "configured"
		if cfg.AppToken == "" {
			detail = "SLACK_APP_TOKEN absent (inbound Socket Mode needs it)"
		}
	default:
		detail = "no " + e.SlackTokensFile()
	}
	if jsonOut {
		out := map[string]any{
			"slack":       state,
			"tokens_file": e.SlackTokensFile(),
			"threads":     len(rows),
			"log_dir":     e.ThreadsDir(),
			"api_base":    slackAPIBase(),
			"inbound":     "not implemented (see docs/slack-install.md)",
		}
		if detail != "" {
			out["detail"] = detail
		}
		b, err := json.Marshal(out)
		if err != nil {
			return err
		}
		fmt.Println(string(b))
		return nil
	}
	fmt.Printf("slack: %s\n", state)
	if detail != "" {
		fmt.Printf("  %s\n", detail)
	}
	fmt.Printf("tokens file: %s\n", e.SlackTokensFile())
	fmt.Printf("threads bound: %d\n", len(rows))
	fmt.Printf("outbound logs: %s\n", e.ThreadsDir())
	fmt.Printf("inbound: not implemented (see docs/slack-install.md)\n")
	return nil
}

func CmdRelay(e *Env, args []string) error {
	if len(args) == 0 {
		return usageError("missing render|post|status")
	}
	sub := args[0]
	brID, kind := "", ""
	jsonOut := false
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--br-id":
			if i+1 >= len(args) {
				return usageError("--br-id needs ID")
			}
			brID = args[i+1]
			i++
		case "--kind":
			if i+1 >= len(args) {
				return usageError("--kind needs KIND")
			}
			kind = args[i+1]
			i++
		case "--json":
			jsonOut = true
		case "-h", "--help":
			printRelayUsage()
		default:
			return usageError("unknown relay arg %s", args[i])
		}
	}
	switch sub {
	case "render", "post":
		if brID == "" {
			return usageError("%s needs --br-id ID", sub)
		}
		if kind == "" {
			return usageError("%s needs --kind KIND (%s)", sub, strings.Join(eventKinds, "|"))
		}
		if sub == "render" {
			return relayRender(e, brID, kind, jsonOut)
		}
		if jsonOut {
			return usageError("relay post takes no --json")
		}
		return relayPost(e, brID, kind)
	case "status":
		if brID != "" || kind != "" {
			return usageError("relay status takes no --br-id or --kind")
		}
		return relayStatus(e, jsonOut)
	case "-h", "--help":
		printRelayUsage()
	default:
		return usageError("unknown relay command %s (want: render, post, status)", sub)
	}
	return nil
}
