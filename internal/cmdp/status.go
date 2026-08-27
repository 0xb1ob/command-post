package cmdp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func statusSnapshot(e *Env, originFilter string) (string, error) {
	whoJSON, err := muxaWhoJSON(e)
	if err != nil {
		return "", err
	}
	brokerJSON := muxaBrokerJSON()
	jobsBytes, err := JobsListJSON(e)
	if err != nil {
		return "", err
	}
	brOpenJSON, err := brListJSON(e, "--json")
	if err != nil {
		return "", err
	}
	branchesJSON, err := statusBranchMap(e, whoJSON)
	if err != nil {
		return "", err
	}
	candIDs, err := statusCandidateClosedIDs(string(jobsBytes), brOpenJSON, branchesJSON)
	if err != nil {
		return "", err
	}
	brClosedJSON := "[]"
	if len(candIDs) > 0 {
		args := []string{"-s", "closed", "--json"}
		for _, id := range candIDs {
			args = append(args, "--id", id)
		}
		brClosedJSON, err = brListJSON(e, args...)
		if err != nil {
			return "", err
		}
	}
	blockedJSON := "[]"
	if originFilter != "" {
		blockedJSON, err = brBlockedJSON(e)
		if err != nil {
			return "", err
		}
	}
	generatedAt := os.Getenv("CP_STATUS_NOW")
	if generatedAt == "" {
		generatedAt = time.Now().UTC().Format("2006-01-02T15:04:05Z")
	}
	stallSec := defaultStatusStallSec
	if v := os.Getenv("CP_STATUS_STALL_SEC"); v != "" {
		n, err := strconvAtoi(v)
		if err != nil || n < 1 {
			return "", usageError("CP_STATUS_STALL_SEC must be a positive integer (got: %s)", v)
		}
		stallSec = n
	}
	return statusAssemble(whoJSON, brokerJSON, string(jobsBytes), brOpenJSON, brClosedJSON, branchesJSON, generatedAt, e.Home, stallSec, originFilter, blockedJSON)
}

func strconvAtoi(s string) (int, error) {
	return strconvParseInt(s)
}

func statusRenderTable(payload string) error {
	var data map[string]any
	if err := json.Unmarshal([]byte(payload), &data); err != nil {
		return err
	}
	broker, _ := data["broker"].(map[string]any)
	if broker != nil && broker["ok"] == true {
		drawing := "-"
		if d, ok := broker["drawing"].([]any); ok && len(d) > 0 {
			parts := make([]string, len(d))
			for i, x := range d {
				parts[i] = fmt.Sprint(x)
			}
			drawing = strings.Join(parts, ",")
		}
		fmt.Printf("BROKER ok queued=%v done=%v failed=%v drawing=%s\n",
			brokerCounter(broker["queued"]), brokerCounter(broker["done"]),
			brokerCounter(broker["failed"]), drawing)
	} else {
		fmt.Println("BROKER degraded (unavailable) -- nodes below may be stale")
	}
	fmt.Println()
	fmt.Printf("%-16s %-12s %-10s %-8s %-16s %-6s %s\n", "ALIAS", "ROLE", "PHASE", "CLI", "PROJECT", "AGE", "TITLE")
	nowS, _ := data["generated_at"].(string)
	nodes, _ := data["nodes"].([]any)
	for _, ni := range nodes {
		n, _ := ni.(map[string]any)
		fmt.Printf("%-16s %-12s %-10s %-8s %-16s %-6s %v\n",
			strOr(n["alias"], "-"), strOr(n["role"], "-"), strOr(n["phase"], "-"),
			strOr(n["cli"], "-"), strOr(n["project"], "-"),
			age(fmt.Sprint(n["timestamp"]), nowS), strOr(n["title"], "-"))
	}
	return nil
}

func brokerCounter(v any) int {
	if v == nil {
		return 0
	}
	switch x := v.(type) {
	case float64:
		return int(x)
	case int:
		return x
	default:
		return 0
	}
}

func strOr(v any, def string) string {
	if v == nil {
		return def
	}
	s := fmt.Sprint(v)
	if s == "" || s == "<nil>" {
		return def
	}
	return s
}

func age(ts, nowS string) string {
	if ts == "" || nowS == "" {
		return "-"
	}
	t := parseTS(ts)
	now := parseTS(nowS)
	if t == nil || now == nil {
		return "-"
	}
	delta := int(now.Sub(*t).Seconds())
	if delta < 0 {
		delta = 0
	}
	if delta < 60 {
		return fmt.Sprintf("%ds", delta)
	}
	if delta < 3600 {
		return fmt.Sprintf("%dm", delta/60)
	}
	if delta < 86400 {
		return fmt.Sprintf("%dh", delta/3600)
	}
	return fmt.Sprintf("%dd", delta/86400)
}

func statusDashboardAssets(e *Env) (css, js string, err error) {
	dir := e.StatusAssetsDir()
	for _, f := range []string{"nocturne.css", "fleet-dashboard.css", "dashboard.js"} {
		if _, err := os.Stat(filepath.Join(dir, f)); err != nil {
			return "", "", failError("missing dashboard asset: %s/%s", dir, f)
		}
	}
	c1, _ := os.ReadFile(filepath.Join(dir, "nocturne.css"))
	c2, _ := os.ReadFile(filepath.Join(dir, "fleet-dashboard.css"))
	j, _ := os.ReadFile(filepath.Join(dir, "dashboard.js"))
	return string(c1) + string(c2), string(j), nil
}

func statusRenderHTML(e *Env, payload string) error {
	css, js, err := statusDashboardAssets(e)
	if err != nil {
		return err
	}
	json.Unmarshal([]byte(payload), &map[string]any{})
	safe := strings.ReplaceAll(payload, "</", "<\\/")
	doc := fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Command Post Fleet Status</title>
<style>
%s
</style>
</head>
<body class="fleet-dashboard">
<div id="error-banner" class="error-banner hidden" role="alert"></div>
<div id="app"><p class="text-muted" style="padding:var(--space-4)">Loading fleet status&hellip;</p></div>
<script type="application/json" id="fleet-data">%s</script>
<script>
%s
CPStatusDashboard.boot({ live: false });
</script>
</body>
</html>`, css, safe, js)
	fmt.Print(doc)
	return nil
}

func statusRenderHTMLLive(e *Env) (string, error) {
	css, js, err := statusDashboardAssets(e)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Command Post Fleet Status</title>
<style>
%s
</style>
</head>
<body class="fleet-dashboard">
<div id="error-banner" class="error-banner hidden" role="alert"></div>
<div id="app"><p class="text-muted" style="padding:var(--space-4)">Loading fleet status&hellip;</p></div>
<script>
%s
CPStatusDashboard.boot({ live: true });
</script>
</body>
</html>`, css, js), nil
}

func statusPaneJSON(e *Env, alias string) error {
	if alias == "" {
		return failError("status --pane requires an alias")
	}
	args, err := tailCmd(alias)
	if err != nil {
		return err
	}
	out, rc, _ := runCmdCaptureFirst(args)
	type line struct {
		Kind string `json:"kind"`
		Text string `json:"text"`
	}
	if rc == 2 {
		b, _ := json.Marshal(map[string]any{"ok": false, "error": "unknown pane", "alias": alias})
		fmt.Print(string(b))
		os.Exit(2)
	}
	if rc != 0 {
		return usageError("muxa tail failed")
	}
	var lines []line
	for _, l := range splitLines(out) {
		lines = append(lines, line{Kind: classifyTailLine(l), Text: l})
	}
	b, _ := json.Marshal(map[string]any{"ok": true, "alias": alias, "lines": lines})
	fmt.Print(string(b))
	return nil
}

func classifyTailLine(s string) string {
	s = strings.TrimRight(s, "\n")
	trim := strings.TrimLeft(s, " ")
	if trim == "" {
		return "dim"
	}
	if strings.HasPrefix(trim, "#") || strings.HasPrefix(trim, "//") {
		return "dim"
	}
	if strings.HasPrefix(trim, "$") {
		return "cmd"
	}
	low := strings.ToLower(trim)
	if strings.Contains(low, "error") || strings.Contains(low, "fail") || strings.Contains(low, "blocker") {
		return "warn"
	}
	if strings.Contains(low, "dispatch") || strings.Contains(trim, "→") || strings.Contains(trim, "->") {
		return "acc"
	}
	if strings.Contains(low, "ok") || strings.Contains(low, "done") || strings.Contains(trim, "✓") {
		return "ok"
	}
	return "txt"
}

func statusServe(e *Env, port int) error {
	liveHTML, err := statusRenderHTMLLive(e)
	if err != nil {
		return err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, liveHTML)
	})
	mux.HandleFunc("/api/status", func(w http.ResponseWriter, r *http.Request) {
		cmd := exec.Command(e.Prog, "status", "--json")
		out, err := cmd.Output()
		if err != nil {
			if ee, ok := err.(*exec.ExitError); ok {
				w.WriteHeader(500)
				w.Write(ee.Stderr)
				return
			}
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	})
	mux.HandleFunc("/api/pane", func(w http.ResponseWriter, r *http.Request) {
		alias := r.URL.Query().Get("alias")
		cmd := exec.Command(e.Prog, "status", "--pane", alias)
		out, err := cmd.CombinedOutput()
		if err != nil {
			if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 2 {
				w.WriteHeader(http.StatusNotFound)
				w.Write(out)
				return
			}
			http.Error(w, string(out), 500)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write(out)
	})
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return usageError("cannot bind %s (%v)", addr, err)
	}
	boundPort := ln.Addr().(*net.TCPAddr).Port
	fmt.Printf("http://127.0.0.1:%d/\n", boundPort)
	fmt.Fprintln(os.Stderr, "[cmdp] Ctrl-C to stop")
	srv := &http.Server{Handler: mux}
	go func() {
		<-serveSignals()
		srv.Shutdown(context.Background())
	}()
	return srv.Serve(ln)
}

func serveSignals() chan os.Signal {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	return ch
}

func CmdStatus(e *Env, args []string) error {
	jsonOut, htmlOut, serve := false, false, false
	if v := os.Getenv("CP_STATUS_PORT"); v != "" {
		p, err := strconvParseInt(v)
		if err != nil || p < 0 || p > 65535 {
			return usageError("CP_STATUS_PORT must be a port number (got: %s)", v)
		}
	}
	port := effectiveStatusPort(e.Home)
	paneAlias, originFilter := "", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			jsonOut = true
		case "--html":
			htmlOut = true
		case "--serve":
			serve = true
		case "--origin":
			if i+1 >= len(args) {
				return usageError("status --origin needs ID")
			}
			originFilter = args[i+1]
			i++
		case "--pane":
			if i+1 >= len(args) {
				return usageError("status --pane needs ALIAS")
			}
			paneAlias = args[i+1]
			i++
		case "--port":
			if i+1 >= len(args) {
				return usageError("status --port needs N")
			}
			p, err := strconvParseInt(args[i+1])
			if err != nil {
				return usageError("status --port must be a non-negative integer (got: %s)", args[i+1])
			}
			port = p
			i++
		case "-h", "--help":
			printStatusUsage()
			os.Exit(2)
		default:
			return usageError("unknown status arg %s", args[i])
		}
	}
	if originFilter != "" && (serve || paneAlias != "") {
		return usageError("status: --origin is mutually exclusive with --serve and --pane")
	}
	if paneAlias != "" && (serve || jsonOut || htmlOut) {
		return usageError("status: --pane is mutually exclusive with --json, --html, and --serve")
	}
	if serve && (jsonOut || htmlOut) {
		return usageError("status: --serve is mutually exclusive with --json and --html")
	}
	if jsonOut && htmlOut {
		return usageError("status: use only one of --json or --html")
	}
	if paneAlias != "" {
		return statusPaneJSON(e, paneAlias)
	}
	if serve {
		return statusServe(e, port)
	}
	result, err := statusSnapshot(e, originFilter)
	if err != nil {
		return err
	}
	if jsonOut {
		fmt.Println(result)
		return nil
	}
	if htmlOut {
		return statusRenderHTML(e, result)
	}
	return statusRenderTable(result)
}

func strconvParseInt(s string) (int, error) {
	var n int
	_, err := fmt.Sscanf(s, "%d", &n)
	return n, err
}
