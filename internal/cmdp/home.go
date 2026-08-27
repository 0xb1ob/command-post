package cmdp

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var (
	// Version is set at build time via -ldflags.
	Version = "dev"
	Commit  = "none"

	defaultGateModel      = "composer-2.5-fast"
	defaultStatusStallSec = 600
	jobIDPattern          = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	projectNamePattern    = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	templateNamePattern   = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
)

// Env holds command-post home and repo root (from the cmdp binary location).
type Env struct {
	Root        string // tracked repo root (parent of bin/)
	Home        string // CP_HOME
	Prog        string // path to this binary
	JobsFile    string
	ThreadsFile string
}

func NewEnv() (*Env, error) {
	prog, err := os.Executable()
	if err != nil {
		return nil, err
	}
	prog, err = filepath.EvalSymlinks(prog)
	if err != nil {
		return nil, err
	}
	root := filepath.Dir(filepath.Dir(prog))
	home := os.Getenv("CP_HOME")
	if home == "" {
		home = root
		if _, err := os.Stat(home); err == nil {
			if resolved, err := filepath.EvalSymlinks(home); err == nil {
				home = resolved
			}
		}
	} else if _, err := os.Stat(filepath.Join(home, "bin", "install.sh")); err == nil {
		// A release binary lives at <prefix>/bin/cmdp, so the executable-relative
		// root is the install prefix, not a checkout — share/, templates/,
		// lib/status/ and bin/install.sh would all resolve under it. When
		// CP_HOME names a real checkout, that is the tracked root too.
		// Deliberately not EvalSymlinks'd: CP_HOME is used verbatim elsewhere.
		root = home
	}
	jf := os.Getenv("CP_JOBS_FILE")
	if jf == "" {
		jf = filepath.Join(home, "state", "jobs.tsv")
	}
	tf := os.Getenv("CP_THREADS_FILE")
	if tf == "" {
		tf = filepath.Join(home, "state", "threads.tsv")
	}
	return &Env{Root: root, Home: home, Prog: prog, JobsFile: jf, ThreadsFile: tf}, nil
}

// effectiveStatusPort is what --serve would bind with no --port: the
// home-derived default unless CP_STATUS_PORT overrides it.
func effectiveStatusPort(home string) int {
	if v := os.Getenv("CP_STATUS_PORT"); v != "" {
		if p, err := strconvParseInt(v); err == nil && p >= 0 && p <= 65535 {
			return p
		}
	}
	return statusPortDefault(home)
}

// statusPortDefault derives the dashboard port from the home path so two
// command-post homes on one machine do not silently collide on a shared
// default. Deterministic per home; --port still wins.
func statusPortDefault(home string) int {
	var h uint32 = 2166136261
	for i := 0; i < len(home); i++ {
		h ^= uint32(home[i])
		h *= 16777619
	}
	return 8765 + int(h%1000)
}

func (e *Env) ClisTSV() string     { return filepath.Join(e.Root, "share", "clis.tsv") }
func (e *Env) FamiliesTSV() string { return filepath.Join(e.Root, "share", "families.tsv") }
func (e *Env) RoutingTSV() string  { return filepath.Join(e.Home, "data", "routing.tsv") }
func (e *Env) ModelsDir() string   { return filepath.Join(e.Home, "data", "models") }
func (e *Env) ModelsConf() string  { return filepath.Join(e.Home, "data", "models.conf") }
func (e *Env) modelsTSV(argv0 string) string {
	return filepath.Join(e.ModelsDir(), argv0+".tsv")
}
func (e *Env) modelsMeta(argv0 string) string {
	return filepath.Join(e.ModelsDir(), argv0+".meta")
}
func (e *Env) TemplatesDir() string    { return filepath.Join(e.Home, "templates") }
func (e *Env) GateRubric() string      { return filepath.Join(e.Root, "templates", "gate-rubric.md") }
func (e *Env) StatusAssetsDir() string { return filepath.Join(e.Root, "lib", "status") }
func (e *Env) InstallSh() string       { return filepath.Join(e.Root, "bin", "install.sh") }

func validateJobID(id string) error {
	if !jobIDPattern.MatchString(id) {
		return failError("invalid job id: %s (br id; no whitespace)", id)
	}
	return nil
}

func requireNoCTL(field, val string) error {
	if val == "" {
		return usageError("empty %s=", field)
	}
	if strings.ContainsAny(val, "\t\n") {
		return usageError("invalid %s: tabs and newlines are not allowed", field)
	}
	return nil
}
