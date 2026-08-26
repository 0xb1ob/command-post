package cp

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"
)

var cliDerivePreference = []string{"agent", "cursor-agent", "claude"}

var shippedDefaults = map[string][]string{
	"researcher":    {"agent", "--model", "cursor-grok-4.6-high-fast"},
	"implementer":   {"agent", "--model", "composer-2.5-fast"},
	"gate-reviewer": {"agent", "--model", "composer-2.5-fast"},
}

type roleResolution struct {
	Argv   []string
	Argv0  string
	Source string
	Reason string
}

func listSupportedCLIs(e *Env) ([]string, error) {
	f, err := os.Open(e.ClisTSV())
	if err != nil {
		return nil, nil
	}
	defer f.Close()
	var clis []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) > 0 && parts[0] != "" {
			clis = append(clis, parts[0])
		}
	}
	sort.Strings(clis)
	return clis, nil
}

func loadForbidCLIs(e *Env) []string {
	f, err := os.Open(e.RoutingTSV())
	if err != nil {
		return nil
	}
	defer f.Close()
	var forbid []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) >= 2 && parts[0] == "forbid" {
			forbid = append(forbid, parts[1])
		}
	}
	return forbid
}

func cliIsSupported(e *Env, argv0 string) bool {
	clis, _ := listSupportedCLIs(e)
	for _, c := range clis {
		if c == argv0 {
			return true
		}
	}
	return false
}

func cliIsForbidden(forbid []string, argv0 string) bool {
	for _, f := range forbid {
		if f == argv0 {
			return true
		}
	}
	return false
}

func cliDefaultModel(e *Env, argv0 string) string {
	f, err := os.Open(e.ClisTSV())
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) >= 4 && parts[0] == argv0 {
			return parts[3]
		}
	}
	return ""
}

func cliKindReceipt(e *Env, argv0 string) (kind, receipt string) {
	f, err := os.Open(e.ClisTSV())
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) >= 3 && parts[0] == argv0 {
			return parts[1], parts[2]
		}
	}
	return "", ""
}

func listDerivedCandidates(e *Env) []string {
	forbid := loadForbidCLIs(e)
	supported, _ := listSupportedCLIs(e)
	var out []string
	for _, name := range supported {
		if cliIsForbidden(forbid, name) {
			continue
		}
		if lookPath(name) != "" {
			out = append(out, name)
		}
	}
	return out
}

func composeCLIArgv(e *Env, cli string) []string {
	argv := []string{cli}
	if model := cliDefaultModel(e, cli); model != "" {
		argv = append(argv, "--model", model)
	}
	return argv
}

func pickDerivedCLI(candidates []string) string {
	if len(candidates) == 0 {
		return ""
	}
	if len(candidates) == 1 {
		return candidates[0]
	}
	var picked []string
	for _, p := range cliDerivePreference {
		for _, c := range candidates {
			if c == p {
				picked = append(picked, c)
			}
		}
	}
	for _, c := range candidates {
		found := false
		for _, p := range picked {
			if p == c {
				found = true
				break
			}
		}
		if !found {
			picked = append(picked, c)
		}
	}
	return picked[0]
}

func resolveRoleArgv(e *Env, role string) roleResolution {
	forbid := loadForbidCLIs(e)
	shipped := append([]string{}, shippedDefaults[role]...)
	var argv []string
	found := false
	source := "shipped"
	reason := ""

	if f, err := os.Open(e.RoutingTSV()); err == nil {
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.Split(line, "\t")
			if parts[0] == "forbid" || parts[0] != role {
				continue
			}
			if len(parts) > 1 {
				argv = parts[1:]
				found = true
				source = "routing"
				reason = fmt.Sprintf("data/routing.tsv row for role %s", role)
			}
		}
		f.Close()
	}

	if found {
		return roleResolution{Argv: argv, Argv0: argv[0], Source: source, Reason: reason}
	}

	if lookPath(shipped[0]) != "" && !cliIsForbidden(forbid, shipped[0]) {
		return finishRoleArgv(e, role, roleResolution{
			Argv: shipped, Argv0: shipped[0], Source: "shipped",
			Reason: fmt.Sprintf("shipped default CLI %s is installed", shipped[0]),
		})
	}

	candidates := listDerivedCandidates(e)
	if len(candidates) == 1 {
		argv = composeCLIArgv(e, candidates[0])
		return finishRoleArgv(e, role, roleResolution{
			Argv: argv, Argv0: candidates[0], Source: "derived",
			Reason: fmt.Sprintf("only installed worker CLI: %s", candidates[0]),
		})
	}
	if len(candidates) > 1 {
		picked := pickDerivedCLI(candidates)
		argv = composeCLIArgv(e, picked)
		return finishRoleArgv(e, role, roleResolution{
			Argv: argv, Argv0: picked, Source: "derived",
			Reason: fmt.Sprintf("preference order among installed CLIs (picked %s)", picked),
		})
	}
	return finishRoleArgv(e, role, roleResolution{
		Argv: shipped, Argv0: shipped[0], Source: "derived",
		Reason: "no worker CLI installed",
	})
}

func finishRoleArgv(e *Env, role string, r roleResolution) roleResolution {
	if r.Source == "routing" || len(r.Argv) == 0 {
		return r
	}
	argv, err := applyRubric(e, role, r.Argv)
	if err != nil {
		handleErr(err)
	}
	r.Argv = argv
	if len(argv) > 0 {
		r.Argv0 = argv[0]
	}
	return r
}

func validateWorkerArgv0(e *Env, argv0, role, source string) error {
	if _, err := os.Stat(e.ClisTSV()); err != nil {
		return failError("missing CLI registry: %s", e.ClisTSV())
	}
	if !cliIsSupported(e, argv0) {
		fmt.Fprintf(os.Stderr, "[cp] error: worker CLI %q is not in share/clis.tsv (role=%s, source=%s)\n", argv0, role, source)
		fmt.Fprintln(os.Stderr, "Use a supported CLI from share/clis.tsv, or pass an explicit -- CMD override.")
		fmt.Fprintln(os.Stderr, "bin/cp doctor lists installed CLIs.")
		os.Exit(2)
	}
	if cliIsForbidden(loadForbidCLIs(e), argv0) {
		fmt.Fprintf(os.Stderr, "[cp] error: worker CLI %q is forbidden (forbid row in data/routing.tsv, role=%s)\n", argv0, role)
		fmt.Fprintln(os.Stderr, "Remove the forbid row or pick another CLI for that role in data/routing.tsv.")
		os.Exit(2)
	}
	return nil
}

func requireWorkerCmd(e *Env, argv0, role, source string) error {
	if err := validateWorkerArgv0(e, argv0, role, source); err != nil {
		return err
	}
	if lookPath(argv0) != "" {
		return nil
	}
	candidates := listDerivedCandidates(e)
	fmt.Fprintf(os.Stderr, "[cp] error: worker CLI %q not on PATH (role=%s, source=%s)\n", argv0, role, source)
	if len(candidates) == 0 {
		installable, _ := listSupportedCLIs(e)
		if len(installable) > 0 {
			fmt.Fprintf(os.Stderr, "Install one of: %s (see share/clis.tsv).\n", strings.Join(installable, ", "))
		} else {
			fmt.Fprintln(os.Stderr, "Install a supported worker CLI listed in share/clis.tsv.")
		}
	} else {
		fmt.Fprintf(os.Stderr, "Install %q, or set that role in data/routing.tsv to an installed CLI from share/clis.tsv.\n", argv0)
	}
	fmt.Fprintln(os.Stderr, "bin/cp doctor lists installed CLIs.")
	os.Exit(2)
	return nil
}

func announceRoutingResolution(role, source, reason string, argv []string) {
	fmt.Fprintf(os.Stderr, "[cp] routing: role=%s argv=%q source=%s (%s)\n", role, strings.Join(argv, " "), source, reason)
}

func dispatchRoleFromTemplate(template string) string {
	if template == "research" {
		return "researcher"
	}
	return "implementer"
}
