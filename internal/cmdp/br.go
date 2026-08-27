package cmdp

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

func brJSONStdoutCheck(raw, context string, exitCode int) error {
	var data json.RawMessage
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return nil
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil
	}
	if _, ok := envelope["error"]; !ok {
		return nil
	}
	var errObj struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	}
	if err := json.Unmarshal(envelope["error"], &errObj); err != nil {
		return &exitError{code: exitCode, msg: fmt.Sprintf("%s: BR_ERROR: %v", context, envelope["error"])}
	}
	code := errObj.Code
	if code == "" {
		code = "BR_ERROR"
	}
	msg := errObj.Message
	if msg == "" {
		msg = code
	}
	return &exitError{code: exitCode, msg: fmt.Sprintf("%s: %s: %s", context, code, msg)}
}

func brIssueLabelValue(e *Env, id, prefix string) (string, error) {
	argv, err := brShowArgv(e)
	if err != nil {
		return "", err
	}
	args := append(append([]string{}, argv...), id)
	out, err := runCmdCaptureIn(e.Home, args[0], args[1:]...)
	if err != nil {
		return "", err
	}
	var data any
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return "", err
	}
	var issue map[string]any
	switch v := data.(type) {
	case []any:
		if len(v) == 0 {
			return "", fmt.Errorf("no issue")
		}
		issue, _ = v[0].(map[string]any)
	case map[string]any:
		issue = v
	}
	if issue == nil {
		return "", fmt.Errorf("no labels")
	}
	labels, _ := issue["labels"].([]any)
	for _, l := range labels {
		s, _ := l.(string)
		if strings.HasPrefix(s, prefix) {
			return s[len(prefix):], nil
		}
	}
	return "", fmt.Errorf("no label")
}

func brListJSON(e *Env, extraArgs ...string) (string, error) {
	prefix, err := brPrefix(e)
	if err != nil {
		return "", err
	}
	args := append(append(prefix, "list", "--limit", "0"), extraArgs...)
	out, err := runCmdCapture(args[0], args[1:]...)
	if err != nil {
		return "", err
	}
	if err := brJSONStdoutCheck(out, "br list --json", 1); err != nil {
		return "", err
	}
	return normalizeBRList(out)
}

func brBlockedJSON(e *Env) (string, error) {
	prefix, err := brBlockedPrefix(e)
	if err != nil {
		return "", err
	}
	args := append(prefix, "blocked", "--limit", "0", "--json")
	out, err := runCmdCapture(args[0], args[1:]...)
	if err != nil {
		return "", err
	}
	if err := brJSONStdoutCheck(out, "br blocked --json", 1); err != nil {
		return "", err
	}
	return normalizeBRBlocked(out)
}

type brIssue struct {
	ID        string   `json:"id"`
	Title     any      `json:"title"`
	Status    any      `json:"status"`
	UpdatedAt any      `json:"updated_at"`
	Labels    []string `json:"labels"`
}

func normalizeBRList(raw string) (string, error) {
	var data any
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return "", usageError("br list --json: not JSON")
	}
	rows, err := extractIssues(data, "br list --json")
	if err != nil {
		return "", err
	}
	out := make([]brIssue, 0, len(rows))
	for _, r := range rows {
		id, _ := r["id"].(string)
		if id == "" {
			return "", usageError("br list --json: missing id")
		}
		labels := labelSlice(r["labels"])
		out = append(out, brIssue{
			ID: id, Title: r["title"], Status: r["status"],
			UpdatedAt: r["updated_at"], Labels: labels,
		})
	}
	b, err := json.Marshal(out)
	return string(b), err
}

func normalizeBRBlocked(raw string) (string, error) {
	var data any
	if err := json.Unmarshal([]byte(raw), &data); err != nil {
		return "", usageError("br blocked --json: not JSON")
	}
	rows, err := extractIssues(data, "br blocked --json")
	if err != nil {
		return "", err
	}
	type blockedIssue struct {
		brIssue
		BlockedBy      []string `json:"blocked_by"`
		BlockedByCount any      `json:"blocked_by_count"`
	}
	out := make([]blockedIssue, 0, len(rows))
	for _, r := range rows {
		id, _ := r["id"].(string)
		if id == "" {
			return "", usageError("br blocked --json: missing id")
		}
		bb := []string{}
		if v, ok := r["blocked_by"].([]any); ok {
			for _, x := range v {
				bb = append(bb, fmt.Sprint(x))
			}
		}
		out = append(out, blockedIssue{
			brIssue: brIssue{
				ID: id, Title: r["title"], Status: r["status"],
				UpdatedAt: r["updated_at"], Labels: labelSlice(r["labels"]),
			},
			BlockedBy:      bb,
			BlockedByCount: r["blocked_by_count"],
		})
	}
	b, err := json.Marshal(out)
	return string(b), err
}

func extractIssues(data any, ctx string) ([]map[string]any, error) {
	switch v := data.(type) {
	case map[string]any:
		if _, ok := v["error"]; ok {
			b, _ := json.Marshal(v)
			if err := brJSONStdoutCheck(string(b), ctx, 1); err != nil {
				return nil, err
			}
		}
		issues, ok := v["issues"].([]any)
		if !ok {
			if dataArr, ok := v["data"].([]any); ok && ctx == "br blocked --json" {
				issues = dataArr
			} else {
				return nil, usageError("%s: envelope missing issues array", ctx)
			}
		}
		return toIssueMaps(issues, ctx)
	case []any:
		return toIssueMaps(v, ctx)
	default:
		return nil, usageError("%s: expected an array or envelope with issues", ctx)
	}
}

func toIssueMaps(items []any, ctx string) ([]map[string]any, error) {
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		m, ok := item.(map[string]any)
		if !ok {
			return nil, usageError("%s: expected objects", ctx)
		}
		out = append(out, m)
	}
	return out, nil
}

func labelSlice(v any) []string {
	arr, _ := v.([]any)
	var labels []string
	for _, x := range arr {
		if s, ok := x.(string); ok {
			labels = append(labels, s)
		}
	}
	return labels
}

func brCreateSupportsSlug() bool {
	if lookPath("br") == "" {
		return false
	}
	out, _ := runCmdCapture("br", "create", "--help")
	return strings.Contains(out, "--slug <SLUG>")
}

func brVersionMatches(e *Env) bool {
	if lookPath("br") == "" {
		return false
	}
	out, _ := runCmdCapture("br", "--version")
	want := "br " + cpBRPinnedVersion(e)
	return out == want
}

func cpBRPinnedVersion(e *Env) string {
	if v := os.Getenv("CP_BR_VERSION_PIN"); v != "" {
		return strings.TrimPrefix(v, "v")
	}
	return readInstallPin(e, `BR_VERSION_PIN="`, `"`, true)
}

func cpMuxaPinnedVersion(e *Env) string {
	if v := os.Getenv("CP_MUXA_VERSION_PIN"); v != "" {
		return v
	}
	return readInstallPin(e, `MUXA_VERSION_PIN="`, `"`, false)
}

func cmdpPinnedVersion(e *Env) string {
	if v := os.Getenv("CP_VERSION_PIN"); v != "" {
		return strings.TrimPrefix(v, "v")
	}
	return readInstallPin(e, `CMDP_VERSION_PIN="`, `"`, false)
}

func readInstallPin(e *Env, prefix, suffix string, stripV bool) string {
	data, err := os.ReadFile(e.InstallSh())
	if err != nil {
		return ""
	}
	for _, line := range splitLines(string(data)) {
		if i := strings.Index(line, prefix); i >= 0 {
			rest := line[i+len(prefix):]
			if j := strings.Index(rest, suffix); j >= 0 {
				v := rest[:j]
				if stripV {
					v = strings.TrimPrefix(v, "v")
				}
				return v
			}
		}
	}
	return ""
}

func muxaVersionMatches(e *Env) bool {
	if lookPath("muxa") == "" {
		return false
	}
	out, _ := runCmdCapture("muxa", "version")
	fields := strings.Fields(out)
	if len(fields) == 0 {
		return false
	}
	return fields[0] == cpMuxaPinnedVersion(e)
}

func cmdpVersionMatches() bool {
	want := os.Getenv("CP_VERSION_PIN")
	if want == "" {
		return true
	}
	want = strings.TrimPrefix(want, "v")
	if Version == "dev" {
		return true
	}
	return Version == want
}

func brCommentsAdd(e *Env, id, file string) error {
	db, err := resolveBeadsDB(e)
	if err != nil {
		return err
	}
	cmd := exec.Command("br", "--db", db, "comments", "add", id, "--file", file, "-q")
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

func brCommentsList(e *Env, id string) (string, error) {
	db, err := resolveBeadsDB(e)
	if err != nil {
		return "", err
	}
	out, err := runCmdCapture("br", "--db", db, "comments", "list", id, "--json")
	if err != nil {
		return "", err
	}
	if err := brJSONStdoutCheck(out, "br comments list --json", 2); err != nil {
		return "", err
	}
	return out, nil
}
