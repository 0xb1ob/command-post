package cmdp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func artifactDir(e *Env, id string) string {
	return strings.TrimRight(e.Home, "/") + "/state/artifacts/" + id
}

func artifactReport(e *Env, id string) string {
	return artifactDir(e, id) + "/report.md"
}

func CmdArtifact(e *Env, args []string) error {
	if len(args) == 0 {
		return usageError("missing path|add|get")
	}
	switch args[0] {
	case "path":
		if len(args) != 2 {
			return usageError("path takes ID only")
		}
		id := args[1]
		if err := validateJobID(id); err != nil {
			return err
		}
		dir := artifactDir(e, id)
		report := artifactReport(e, id)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
		fmt.Println(report)
		return nil
	case "add":
		if len(args) != 3 {
			return usageError("add takes ID FILE only")
		}
		return artifactAdd(e, args[1], args[2])
	case "get":
		if len(args) != 2 {
			return usageError("get takes ID only")
		}
		body, err := artifactGet(e, args[1])
		if err != nil {
			return err
		}
		fmt.Print(body)
		return nil
	case "-h", "--help":
		printArtifactUsage()
		os.Exit(2)
	default:
		return usageError("unknown artifact command %s (want: path, add, get)", args[0])
	}
	return nil
}

func artifactAdd(e *Env, id, file string) error {
	if err := validateJobID(id); err != nil {
		return err
	}
	if st, err := os.Stat(file); err != nil || st.IsDir() {
		return failError("not a file: %s", file)
	}
	if err := requireBR(); err != nil {
		return err
	}
	if err := requireBRIssue(e, id); err != nil {
		return err
	}
	info, _ := os.Stat(file)
	tmp, err := os.CreateTemp("", "cmdp-artifact.*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := tmp.WriteString("artifact:v1\n"); err != nil {
		tmp.Close()
		return err
	}
	data, err := os.ReadFile(file)
	if err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()
	if err := brCommentsAdd(e, id, tmpPath); err != nil {
		return failError("br comments add failed for %s", id)
	}
	out := map[string]any{"br_id": id, "bytes": info.Size()}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
	return nil
}

func artifactGet(e *Env, id string) (string, error) {
	if err := validateJobID(id); err != nil {
		return "", err
	}
	if err := requireBR(); err != nil {
		return "", err
	}
	raw, err := brCommentsList(e, id)
	if err != nil {
		return "", failError("cannot list comments for %s", id)
	}
	var comments []map[string]any
	if err := json.Unmarshal([]byte(raw), &comments); err != nil {
		return "", usageError("br comments list --json: not JSON")
	}
	type bestT struct {
		key  string
		idN  int
		text string
	}
	var best *bestT
	for _, c := range comments {
		text, _ := c["text"].(string)
		if text == "" {
			continue
		}
		first := text
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			first = text[:i]
		}
		if first != "artifact:v1" {
			continue
		}
		created := fmt.Sprint(c["created_at"])
		idN := 0
		switch v := c["id"].(type) {
		case float64:
			idN = int(v)
		case int:
			idN = v
		}
		key := fmt.Sprintf("%s\t%09d", created, idN)
		if best == nil || key >= best.key {
			best = &bestT{key: key, idN: idN, text: text}
		}
	}
	if best == nil {
		return "", failError("no artifact:v1 comment on %s", id)
	}
	text := best.text
	switch {
	case strings.HasPrefix(text, "artifact:v1\r\n"):
		return text[len("artifact:v1\r\n"):], nil
	case strings.HasPrefix(text, "artifact:v1\n"):
		return text[len("artifact:v1\n"):], nil
	case text == "artifact:v1":
		return "", nil
	default:
		if i := strings.IndexByte(text, '\n'); i >= 0 {
			return text[i+1:], nil
		}
		return "", nil
	}
}

func artifactTeardownGuard(e *Env, id string) error {
	art := artifactDir(e, id)
	st, err := os.Stat(art)
	if err != nil || !st.IsDir() {
		return nil
	}
	var extras []string
	filepath.Walk(art, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		rel, err := filepath.Rel(art, path)
		if err != nil || rel == "report.md" {
			return nil
		}
		extras = append(extras, path)
		return nil
	})
	if len(extras) == 0 {
		return nil
	}
	sort.Strings(extras)
	fmt.Fprintln(os.Stderr, "[cmdp] fail: artifact dir has unmirrored files — keep the lease; mirror with artifact add or copy out before teardown:")
	for _, p := range extras {
		fmt.Fprintf(os.Stderr, "  %s\n", p)
	}
	os.Exit(1)
	return nil
}

func artifactTeardownClean(e *Env, id string) {
	art := artifactDir(e, id)
	os.RemoveAll(art)
}
