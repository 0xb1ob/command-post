package cp

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func CmdDoctor(e *Env, args []string) error {
	loadJobModelEnv()
	jsonOut := false
	for _, a := range args {
		switch a {
		case "--json":
			jsonOut = true
		case "-h", "--help":
			printDoctorUsage()
			os.Exit(2)
		default:
			return usageError("unexpected arg %s", a)
		}
	}
	hostTools := []string{"muxa", "br", "treehouse", "git", "tmux"}
	brSlugOK := brCreateSupportsSlug()
	brVersionOK := brVersionMatches(e)
	muxaVersionOK := muxaVersionMatches(e)
	brTrackerOK := true
	beadsDB := filepath.Join(e.Home, ".beads", "beads.db")
	if _, err := os.Stat(beadsDB); err == nil {
		out, err := runCmdCapture("br", "--db", beadsDB, "list", "--json")
		brTrackerOK = err == nil && out != ""
	}
	clis, _ := listSupportedCLIs(e)
	forbid := loadForbidCLIs(e)
	hostMissing := 0
	for _, ht := range hostTools {
		if ht == "muxa" && (os.Getenv("MUXA_WHO_CMD") != "" || lookPath("muxa") != "") {
			continue
		}
		if lookPath(ht) == "" {
			hostMissing++
		}
	}
	if jsonOut {
		out, exitCode := doctorJSON(e, hostTools, brSlugOK, brVersionOK, muxaVersionOK, brTrackerOK, forbid)
		fmt.Println(out)
		os.Exit(exitCode)
	}
	fmt.Printf("command-post home: %s\n", e.Home)
	fmt.Println("\nHost tools:")
	for _, ht := range hostTools {
		p := lookPath(ht)
		if p != "" || (ht == "muxa" && os.Getenv("MUXA_WHO_CMD") != "") {
			if p == "" {
				p = "shim"
			}
			fmt.Printf("  %s: ok (%s)\n", ht, p)
		} else {
			fmt.Printf("  %s: MISSING\n", ht)
		}
	}
	fmt.Println("\nSupported worker CLIs (share/clis.tsv):")
	for _, name := range clis {
		p := lookPath(name)
		kind, receipt := cliKindReceipt(e, name)
		if p != "" {
			fmt.Printf("  %s (%s/%s): ok (%s)\n", name, kind, receipt, p)
		} else {
			fmt.Printf("  %s (%s/%s): missing\n", name, kind, receipt)
		}
	}
	fmt.Println("\nRouting:")
	for _, role := range []string{"researcher", "implementer", "gate-reviewer"} {
		r := resolveRoleArgv(e, role)
		p := lookPath(r.Argv0)
		fmt.Printf("  %s: %s (source=%s)", role, strings.Join(r.Argv, " "), r.Source)
		if cliIsForbidden(forbid, r.Argv0) {
			fmt.Print(" FORBIDDEN")
		} else if p != "" {
			fmt.Print(" ok")
		} else {
			fmt.Print(" MISSING")
		}
		fmt.Println()
	}
	printDoctorModels(e, clis)
	if len(forbid) > 0 {
		fmt.Printf("\nForbid: %s\n", strings.Join(forbid, " "))
	}
	if hostMissing != 0 {
		fmt.Fprintln(os.Stderr, "\n[cp] error: one or more host tools are missing — run bin/install.sh")
		os.Exit(2)
	}
	if !muxaVersionOK {
		pin := cpMuxaPinnedVersion(e)
		fmt.Fprintf(os.Stderr, "\n[cp] error: muxa is not %s — run bin/install.sh (pins muxa %s)\n", pin, pin)
		os.Exit(2)
	}
	if !brSlugOK {
		fmt.Fprintln(os.Stderr, "\n[cp] error: br create lacks --slug — run bin/install.sh (AGENTS.md intake requires it)")
		os.Exit(2)
	}
	if !brVersionOK {
		pin := cpBRPinnedVersion(e)
		fmt.Fprintf(os.Stderr, "\n[cp] error: br is not %s — run bin/install.sh (pins beads_rust v%s)\n", pin, pin)
		os.Exit(2)
	}
	if !brTrackerOK {
		fmt.Fprintf(os.Stderr, "\n[cp] error: home tracker schema mismatch — run: br --db %s doctor migrate-schema plan\n", beadsDB)
		os.Exit(2)
	}
	return nil
}

func doctorJSON(e *Env, hostTools []string, brSlugOK, brVersionOK, muxaVersionOK, brTrackerOK bool, forbid []string) (string, int) {
	host := map[string]map[string]any{}
	for _, ht := range hostTools {
		p := lookPath(ht)
		host[ht] = map[string]any{"ok": p != "", "path": p}
	}
	if host["muxa"]["ok"].(bool) {
		host["muxa"]["version_ok"] = muxaVersionOK
	}
	if host["br"]["ok"].(bool) {
		host["br"]["create_slug"] = brSlugOK
		host["br"]["version_ok"] = brVersionOK
		host["br"]["tracker_ok"] = brTrackerOK
	}
	clis := map[string]any{}
	if data, err := os.ReadFile(e.ClisTSV()); err == nil {
		for _, line := range splitLines(string(data)) {
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}
			parts := strings.Split(line, "\t")
			if len(parts) >= 3 {
				p := lookPath(parts[0])
				clis[parts[0]] = map[string]any{
					"kind": parts[1], "receipt": parts[2],
					"installed": p != "", "path": p,
				}
			}
		}
	}
	roles := map[string]any{}
	for _, role := range []string{"researcher", "implementer", "gate-reviewer"} {
		r := resolveRoleArgv(e, role)
		p := lookPath(r.Argv0)
		roles[role] = map[string]any{
			"argv": r.Argv, "argv0": r.Argv0, "source": r.Source,
			"installed": p != "", "path": p,
			"forbidden":    cliIsForbidden(forbid, r.Argv0),
			"model_status": modelStatus(e, r.Argv0, argvModel(r.Argv)),
		}
	}
	var missing []map[string]any
	for ht, info := range host {
		if !info["ok"].(bool) {
			missing = append(missing, map[string]any{
				"what": ht, "kind": "host",
				"fix": fmt.Sprintf("install %s (bin/install.sh for muxa, br, treehouse)", ht),
			})
		}
	}
	if host["muxa"]["ok"].(bool) && !muxaVersionOK {
		pin := cpMuxaPinnedVersion(e)
		missing = append(missing, map[string]any{
			"what": fmt.Sprintf("muxa %s", pin), "kind": "host-version",
			"fix": fmt.Sprintf("run bin/install.sh (pins muxa %s)", pin),
		})
	}
	if host["br"]["ok"].(bool) && !brSlugOK {
		missing = append(missing, map[string]any{
			"what": "br --slug", "kind": "host-feature",
			"fix": "run bin/install.sh (AGENTS.md intake requires --slug on br create)",
		})
	}
	if host["br"]["ok"].(bool) && !brVersionOK {
		pin := cpBRPinnedVersion(e)
		missing = append(missing, map[string]any{
			"what": fmt.Sprintf("br %s", pin), "kind": "host-version",
			"fix": fmt.Sprintf("run bin/install.sh (pins beads_rust v%s)", pin),
		})
	}
	if host["br"]["ok"].(bool) && !brTrackerOK {
		missing = append(missing, map[string]any{
			"what": "br tracker schema", "kind": "host-schema",
			"fix": "br --db <home>/.beads/beads.db doctor migrate-schema plan (then apply --plan-token)",
		})
	}
	seen := map[string]bool{}
	for role, rinfo := range roles {
		m := rinfo.(map[string]any)
		argv0, _ := m["argv0"].(string)
		if argv0 != "" && !m["installed"].(bool) && !seen[argv0] {
			seen[argv0] = true
			fix := fmt.Sprintf("install %s or edit data/routing.tsv for role %s", argv0, role)
			if m["source"] == "derived" {
				names, _ := listSupportedCLIs(e)
				if len(names) > 0 {
					fix = fmt.Sprintf("install one of: %s (see share/clis.tsv)", strings.Join(names, ", "))
				}
			}
			missing = append(missing, map[string]any{
				"what": argv0, "kind": "routed-but-missing",
				"role": role, "source": m["source"], "fix": fix,
			})
		}
	}
	out := map[string]any{
		"home": e.Home, "host": host, "clis": clis,
		"roles": roles, "forbid": forbid, "missing": missing,
		"models":     doctorModelsJSON(e),
		"cp_version": Version, "cp_version_ok": cpVersionMatches(),
	}
	b, _ := json.Marshal(out)
	exitCode := 0
	if !muxaVersionOK || !brSlugOK || !brVersionOK || !brTrackerOK {
		exitCode = 2
	}
	for _, info := range host {
		if !info["ok"].(bool) {
			exitCode = 2
		}
	}
	return string(b), exitCode
}
