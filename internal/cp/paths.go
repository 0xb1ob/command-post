package cp

import (
	"os"
	"path/filepath"
	"strings"
)

func normalizePath(p string) (string, error) {
	info, err := os.Stat(p)
	var result string
	if err == nil && info.IsDir() {
		result, err = filepath.EvalSymlinks(p)
	} else {
		dir := filepath.Dir(p)
		base := filepath.Base(p)
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			abs, err := filepath.EvalSymlinks(dir)
			if err != nil {
				return p, nil
			}
			result = filepath.Join(abs, base)
		} else {
			return p, nil
		}
	}
	if err != nil {
		return p, err
	}
	return result, nil
}

func stripPrivatePrefix(p string) string {
	if strings.HasPrefix(p, "/private/var/") {
		return "/var/" + p[len("/private/var/"):]
	}
	if strings.HasPrefix(p, "/private/tmp/") {
		return "/tmp/" + p[len("/private/tmp/"):]
	}
	return p
}

func absGitCommon(dir string) (string, error) {
	out, err := gitOutput(dir, "rev-parse", "--git-common-dir")
	if err != nil {
		return "", err
	}
	g := out
	if !filepath.IsAbs(g) {
		g = filepath.Join(dir, g)
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(g))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(g)), nil
}

func primaryWorktree(repo string) (string, error) {
	out, err := gitOutput(repo, "worktree", "list", "--porcelain")
	if err != nil {
		return "", err
	}
	for _, line := range splitLines(out) {
		if len(line) > 9 && line[:9] == "worktree " {
			return line[9:], nil
		}
	}
	return "", nil
}

func defaultBaseBranch(repo string) string {
	ref, _ := gitOutput(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
	if len(ref) > 7 && ref[:7] == "origin/" {
		return ref[7:]
	}
	return "main"
}

func splitLines(s string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			line := s[start:i]
			if len(line) > 0 && line[len(line)-1] == '\r' {
				line = line[:len(line)-1]
			}
			lines = append(lines, line)
			start = i + 1
		}
	}
	if start < len(s) {
		line := s[start:]
		if len(line) > 0 && line[len(line)-1] == '\r' {
			line = line[:len(line)-1]
		}
		lines = append(lines, line)
	}
	return lines
}
