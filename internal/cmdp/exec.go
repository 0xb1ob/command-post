package cmdp

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

func lookPath(name string) string {
	p, err := exec.LookPath(name)
	if err != nil {
		return ""
	}
	return p
}

func runCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}

func runCmdIn(dir, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin
	return cmd.Run()
}

func runCmdCapture(name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		if stderr.Len() > 0 {
			return "", fmt.Errorf("%s: %s", err, strings.TrimSpace(stderr.String()))
		}
		return "", err
	}
	return strings.TrimRight(stdout.String(), "\n"), nil
}

func runCmdCaptureIn(dir, name string, args ...string) (string, error) {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err != nil {
		if stderr.Len() > 0 {
			return "", fmt.Errorf("%s: %s", err, strings.TrimSpace(stderr.String()))
		}
		return "", err
	}
	return strings.TrimRight(stdout.String(), "\n"), nil
}

func gitOutput(dir string, args ...string) (string, error) {
	return runCmdCaptureIn(dir, "git", args...)
}

func gitRun(dir string, args ...string) error {
	return runCmdIn(dir, "git", args...)
}

func splitEnvCmd(envVar string) []string {
	v := os.Getenv(envVar)
	if v == "" {
		return nil
	}
	// Executable stub scripts (BR_LIST_CMD, etc.) must receive argv suffixes;
	// shell snippets (MUXA_WHO_CMD="printf '[]\n'") need bash -c.
	if !strings.ContainsAny(v, " \t") {
		if st, err := os.Stat(v); err == nil && !st.IsDir() {
			if st.Mode()&0o111 != 0 || strings.HasSuffix(v, ".sh") {
				return []string{v}
			}
		}
	}
	return []string{"bash", "-c", v}
}

func brShowArgv(e *Env) ([]string, error) {
	if cmd := splitEnvCmd("BR_SHOW_CMD"); cmd != nil {
		return cmd, nil
	}
	if lookPath("br") == "" {
		return nil, usageError("br not on PATH")
	}
	db, err := resolveBeadsDB(e)
	if err != nil {
		return nil, err
	}
	return []string{"br", "--db", db, "show", "--json"}, nil
}

func brPrefix(e *Env) ([]string, error) {
	if cmd := splitEnvCmd("BR_LIST_CMD"); cmd != nil {
		return cmd, nil
	}
	if lookPath("br") == "" {
		return nil, usageError("br not on PATH")
	}
	db, err := resolveBeadsDB(e)
	if err != nil {
		return nil, err
	}
	return []string{"br", "--db", db}, nil
}

func brBlockedPrefix(e *Env) ([]string, error) {
	if cmd := splitEnvCmd("BR_BLOCKED_CMD"); cmd != nil {
		return cmd, nil
	}
	if lookPath("br") == "" {
		return nil, usageError("br not on PATH")
	}
	db, err := resolveBeadsDB(e)
	if err != nil {
		return nil, err
	}
	return []string{"br", "--db", db}, nil
}

func resolveBeadsDB(e *Env) (string, error) {
	if raw := os.Getenv("BR_DB"); raw != "" {
		st, err := os.Stat(raw)
		if err != nil {
			return "", failError("BR_DB is not a beads database: %s", raw)
		}
		if st.IsDir() {
			db := filepathJoin(raw, "beads.db")
			if _, err := os.Stat(db); err != nil {
				return "", failError("BR_DB is a directory but has no beads.db: %s", raw)
			}
			return normalizePath(db)
		}
		return normalizePath(raw)
	}
	dir := filepathJoin(e.Home, ".beads")
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		return "", failError("no .beads at %s — br must run against the command-post home tracker (refusing to init a second database)", e.Home)
	}
	db := filepathJoin(dir, "beads.db")
	if _, err := os.Stat(db); err != nil {
		return "", failError("no beads.db in %s", dir)
	}
	return normalizePath(db)
}

func filepathJoin(a, b string) string {
	return strings.TrimRight(a, "/") + "/" + strings.TrimLeft(b, "/")
}

func requireBR() error {
	if lookPath("br") == "" {
		return usageError("br not on PATH")
	}
	return nil
}

func requireMuxa() error {
	if os.Getenv("MUXA_WHO_CMD") != "" {
		return nil
	}
	if lookPath("muxa") == "" {
		return usageError("muxa not on PATH")
	}
	return nil
}

func requireMuxaBin() error {
	if lookPath("muxa") == "" {
		return usageError("muxa not on PATH — run bin/install.sh")
	}
	return nil
}

func requireTreehouse() error {
	if lookPath("treehouse") == "" {
		return usageError("treehouse not on PATH — run bin/install.sh")
	}
	return nil
}

func whoCmd() ([]string, error) {
	if cmd := splitEnvCmd("MUXA_WHO_CMD"); cmd != nil {
		return cmd, nil
	}
	if err := requireMuxaBin(); err != nil {
		return nil, err
	}
	return []string{"muxa", "who", "--json"}, nil
}

func brokerCmd() []string {
	if cmd := splitEnvCmd("MUXA_BROKER_CMD"); cmd != nil {
		return cmd
	}
	return []string{"muxa", "broker", "status"}
}

func tailCmd(alias string) ([]string, error) {
	if cmd := splitEnvCmd("MUXA_TAIL_CMD"); cmd != nil {
		return append(cmd, alias), nil
	}
	if err := requireMuxaBin(); err != nil {
		return nil, err
	}
	return []string{"muxa", "tail", alias, "-n", "200"}, nil
}
