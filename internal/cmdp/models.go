package cmdp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	defaultModelsTTL     = int64(86400)
	defaultModelsTimeout = 20 * time.Second
	claudeStaticCount    = 3
)

var (
	jobScope = "S"
	jobRisk  = "low"
	jobKind  = ""
	jobRule  = ""

	cursorListingLine = regexp.MustCompile(`^([a-z0-9][a-z0-9.-]*) - (.+)$`)
	claudeFullName    = regexp.MustCompile(`^claude-`)
)

type familyRule struct {
	Name  string
	Re    *regexp.Regexp
	Kinds []string
}

type catalogRow struct {
	Slug    string
	Family  string
	Display string
}

func loadJobModelEnv() {
	if v := os.Getenv("JOB_SCOPE"); v != "" {
		jobScope = strings.ToUpper(v)
	}
	if v := os.Getenv("JOB_RISK"); v != "" {
		jobRisk = strings.ToLower(v)
	}
	if v := os.Getenv("JOB_KIND"); v != "" {
		jobKind = v
	}
}

func modelsConfGet(e *Env, key, def string) string {
	f, err := os.Open(e.ModelsConf())
	if err != nil {
		return def
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if ok && k == key {
			return v
		}
	}
	return def
}

func modelsTTL(e *Env) int64 {
	if v := os.Getenv("CP_MODELS_TTL_SEC"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			return n
		}
	}
	if n, err := strconv.ParseInt(modelsConfGet(e, "ttl_sec", strconv.FormatInt(defaultModelsTTL, 10)), 10, 64); err == nil {
		return n
	}
	return defaultModelsTTL
}

func modelsAllowCSV(e *Env) string {
	if v, ok := os.LookupEnv("CP_MODELS_ALLOW"); ok {
		return v
	}
	return modelsConfGet(e, "allow", "cursor,grok,anthropic")
}

func modelsPreferCSV(e *Env, kind string) string {
	if kind == "claude" {
		return modelsConfGet(e, "prefer.claude", "anthropic")
	}
	return modelsConfGet(e, "prefer.cursor", "cursor,grok,anthropic")
}

func csvHas(csv, want string) bool {
	for _, p := range strings.Split(csv, ",") {
		if strings.TrimSpace(p) == want {
			return true
		}
	}
	return false
}

func loadFamilyRules(e *Env) []familyRule {
	f, err := os.Open(e.FamiliesTSV())
	if err != nil {
		return nil
	}
	defer f.Close()
	var rules []familyRule
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		if len(parts) < 2 {
			continue
		}
		re, err := regexp.Compile(parts[1])
		if err != nil {
			continue
		}
		kinds := []string{"cursor"}
		if len(parts) >= 3 && parts[2] != "" {
			kinds = strings.Split(parts[2], ",")
		}
		rules = append(rules, familyRule{Name: parts[0], Re: re, Kinds: kinds})
	}
	return rules
}

func familyOfSlug(e *Env, slug string) string {
	for _, r := range loadFamilyRules(e) {
		if r.Re.MatchString(slug) {
			return r.Name
		}
	}
	return "other"
}

func claudeSlugOK(slug string) bool {
	switch slug {
	case "fable", "opus", "sonnet":
		return true
	}
	return claudeFullName.MatchString(slug)
}

func argvModel(argv []string) string {
	for i, a := range argv {
		if a == "--model" && i+1 < len(argv) {
			return argv[i+1]
		}
	}
	return ""
}

func argvSetModel(argv []string, slug string) []string {
	out := make([]string, 0, len(argv)+2)
	saw := false
	for i := 0; i < len(argv); i++ {
		if argv[i] == "--model" {
			out = append(out, "--model", slug)
			saw = true
			if i+1 < len(argv) {
				i++
			}
			continue
		}
		out = append(out, argv[i])
	}
	if !saw {
		out = append(out, "--model", slug)
	}
	return out
}

func readMeta(path string) map[string]string {
	out := map[string]string{}
	f, err := os.Open(path)
	if err != nil {
		return out
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if ok {
			out[k] = v
		}
	}
	return out
}

func readCatalogRows(path string) []catalogRow {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	var rows []catalogRow
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, "\t")
		row := catalogRow{Slug: parts[0]}
		if len(parts) > 1 {
			row.Family = parts[1]
		}
		if len(parts) > 2 {
			row.Display = parts[2]
		}
		rows = append(rows, row)
	}
	return rows
}

func slugInCatalog(e *Env, argv0, slug string) bool {
	for _, r := range readCatalogRows(e.modelsTSV(argv0)) {
		if r.Slug == slug {
			return true
		}
	}
	return false
}

func catalogExists(e *Env, argv0 string) bool {
	kind, _ := cliKindReceipt(e, argv0)
	if kind == "claude" {
		return true
	}
	_, err := os.Stat(e.modelsTSV(argv0))
	return err == nil
}

func catalogStatus(e *Env, argv0 string) string {
	kind, _ := cliKindReceipt(e, argv0)
	if kind == "claude" {
		return "static"
	}
	metaPath := e.modelsMeta(argv0)
	tsvPath := e.modelsTSV(argv0)
	meta := readMeta(metaPath)
	if _, err := os.Stat(metaPath); err != nil {
		if _, err := os.Stat(tsvPath); err != nil {
			return "none"
		}
	}
	if meta["static"] == "true" {
		return "static"
	}
	if meta["status"] == "failed" {
		return "failed"
	}
	epoch, err := strconv.ParseInt(meta["fetched_epoch"], 10, 64)
	if err != nil || epoch == 0 {
		return "stale"
	}
	if time.Now().Unix()-epoch > modelsTTL(e) {
		return "stale"
	}
	return "fresh"
}

func catalogCount(e *Env, argv0 string) int {
	kind, _ := cliKindReceipt(e, argv0)
	rows := readCatalogRows(e.modelsTSV(argv0))
	if kind == "claude" && len(rows) == 0 {
		return claudeStaticCount
	}
	return len(rows)
}

func metaIsFresh(e *Env, argv0 string) bool {
	epoch, err := strconv.ParseInt(readMeta(e.modelsMeta(argv0))["fetched_epoch"], 10, 64)
	if err != nil || epoch == 0 {
		return false
	}
	return time.Now().Unix()-epoch <= modelsTTL(e)
}

func writeMeta(e *Env, argv0, status string, static bool) error {
	if err := os.MkdirAll(e.ModelsDir(), 0o755); err != nil {
		return err
	}
	now := time.Now().UTC()
	cliPath := lookPath(argv0)
	ver := ""
	if cliPath != "" {
		if out, err := runCmdCaptureTimeout(3*time.Second, argv0, "--version"); err == nil {
			ver = strings.Split(out, "\n")[0]
		}
	}
	staticS := "false"
	if static {
		staticS = "true"
	}
	body := fmt.Sprintf("fetched_at=%s\nfetched_epoch=%d\ncli_path=%s\ncli_version=%s\nstatus=%s\nstatic=%s\n",
		now.Format("2006-01-02T15:04:05Z"), now.Unix(), cliPath, ver, status, staticS)
	return os.WriteFile(e.modelsMeta(argv0), []byte(body), 0o644)
}

func writeTSV(e *Env, argv0 string, rows []catalogRow) error {
	if err := os.MkdirAll(e.ModelsDir(), 0o755); err != nil {
		return err
	}
	var b strings.Builder
	b.WriteString("# slug\tfamily\tdisplay\n")
	for _, r := range rows {
		b.WriteString(r.Slug + "\t" + r.Family + "\t" + r.Display + "\n")
	}
	return os.WriteFile(e.modelsTSV(argv0), []byte(b.String()), 0o644)
}

func parseCursorListing(e *Env, listing string) []catalogRow {
	header := false
	var rows []catalogRow
	for _, line := range splitLines(listing) {
		if line == "Available models" {
			header = true
			continue
		}
		if !header {
			continue
		}
		m := cursorListingLine.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		slug, display := m[1], m[2]
		if slug == "auto" {
			continue
		}
		rows = append(rows, catalogRow{Slug: slug, Family: familyOfSlug(e, slug), Display: display})
	}
	return rows
}

func runCmdCaptureTimeout(d time.Duration, name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.Output()
	return strings.TrimRight(string(out), "\n"), err
}

func runModelsCmd(argv0 string) (string, error) {
	if v := os.Getenv("CP_MODELS_CATALOG_CMD"); v != "" {
		cmd := splitEnvCmd("CP_MODELS_CATALOG_CMD")
		if len(cmd) == 0 {
			return "", fmt.Errorf("empty CP_MODELS_CATALOG_CMD")
		}
		return runCmdCaptureTimeout(defaultModelsTimeout, cmd[0], cmd[1:]...)
	}
	return runCmdCaptureTimeout(defaultModelsTimeout, argv0, "models")
}

func writeClaudeStatic(e *Env, argv0 string) error {
	rows := []catalogRow{
		{Slug: "fable", Family: "anthropic", Display: "fable (Claude alias)"},
		{Slug: "opus", Family: "anthropic", Display: "opus (Claude alias)"},
		{Slug: "sonnet", Family: "anthropic", Display: "sonnet (Claude alias)"},
	}
	if err := writeTSV(e, argv0, rows); err != nil {
		return err
	}
	return writeMeta(e, argv0, "ok", true)
}

func refreshFailed(e *Env, argv0 string, quiet bool) {
	prev := readMeta(e.modelsMeta(argv0))["fetched_at"]
	_ = writeMeta(e, argv0, "failed", false)
	if quiet {
		return
	}
	if _, err := os.Stat(e.modelsTSV(argv0)); err == nil {
		if prev == "" {
			prev = "unknown"
		}
		fmt.Fprintf(os.Stderr, "[cmdp] models: refresh failed for %s — using catalog from %s\n", argv0, prev)
		return
	}
	fmt.Fprintf(os.Stderr, "[cmdp] models: refresh failed for %s — no catalog\n", argv0)
}

func modelsRefreshCLI(e *Env, argv0 string, quiet bool) error {
	kind, _ := cliKindReceipt(e, argv0)
	if kind == "" {
		if !quiet {
			fmt.Fprintf(os.Stderr, "[cmdp] models: skip %s (not in share/clis.tsv)\n", argv0)
		}
		return fmt.Errorf("unsupported")
	}
	if lookPath(argv0) == "" {
		if !quiet {
			fmt.Fprintf(os.Stderr, "[cmdp] models: skip %s (not on PATH)\n", argv0)
		}
		return fmt.Errorf("not on PATH")
	}
	if kind == "claude" {
		return writeClaudeStatic(e, argv0)
	}
	raw, err := runModelsCmd(argv0)
	if err != nil {
		refreshFailed(e, argv0, quiet)
		return err
	}
	rows := parseCursorListing(e, raw)
	if len(rows) == 0 {
		refreshFailed(e, argv0, quiet)
		return fmt.Errorf("no slugs")
	}
	if err := writeTSV(e, argv0, rows); err != nil {
		return err
	}
	return writeMeta(e, argv0, "ok", false)
}

func modelsEnsureFresh(e *Env, argv0 string) {
	switch catalogStatus(e, argv0) {
	case "fresh", "static":
		return
	case "failed":
		if metaIsFresh(e, argv0) {
			return
		}
		_ = modelsRefreshCLI(e, argv0, false)
	default:
		_ = modelsRefreshCLI(e, argv0, false)
	}
}

func rubricPick(role, scope, risk, cliKind string) (slug, rule string) {
	scope = strings.ToUpper(scope)
	risk = strings.ToLower(risk)
	if cliKind == "claude" {
		switch role {
		case "gate-reviewer":
			return "sonnet", "2"
		case "researcher":
			if scope == "L" {
				return "claude-fable-5", "3"
			}
			return "fable", "4"
		case "implementer":
			if risk == "high" {
				return "opus", "5"
			}
			if scope == "S" {
				return "sonnet", "6"
			}
			return "opus", "7"
		}
		return "sonnet", "8"
	}
	switch role {
	case "gate-reviewer":
		return "composer-2.5-fast", "2"
	case "researcher":
		if scope == "L" {
			return "cursor-grok-4.6-xhigh", "3"
		}
		return "cursor-grok-4.6-high-fast", "4"
	case "implementer":
		if risk == "high" {
			return "cursor-grok-4.6-high", "5"
		}
		if scope == "S" {
			return "composer-2.5-fast", "6"
		}
		return "cursor-grok-4.6-high", "7"
	}
	return "composer-2.5-fast", "8"
}

type parsedSlug struct {
	Base   string
	Effort string
	Fast   bool
}

func parseSlugAttrs(slug string) parsedSlug {
	fast := strings.HasSuffix(slug, "-fast")
	s := slug
	if fast {
		s = strings.TrimSuffix(s, "-fast")
	}
	s = strings.TrimSuffix(s, "-thinking")
	effort := ""
	for _, e := range []string{"xhigh", "medium", "high", "low", "max"} {
		suf := "-" + e
		if strings.HasSuffix(s, suf) {
			effort = e
			s = strings.TrimSuffix(s, suf)
			break
		}
	}
	return parsedSlug{Base: s, Effort: effort, Fast: fast}
}

func effortRank(wanted, have string) int {
	near := map[string][]string{
		"high":   {"high", "xhigh", "medium", "low", "max", ""},
		"xhigh":  {"xhigh", "high", "max", "medium", "low", ""},
		"medium": {"medium", "high", "low", "xhigh", "max", ""},
		"low":    {"low", "medium", "high", "xhigh", "max", ""},
		"max":    {"max", "xhigh", "high", "medium", "low", ""},
		"":       {"", "high", "medium", "low", "xhigh", "max"},
	}
	order, ok := near[wanted]
	if !ok {
		order = near[""]
	}
	for i, v := range order {
		if v == have {
			return i
		}
	}
	return 99
}

func versionKey(slug string) int {
	re := regexp.MustCompile(`\d+`)
	nums := re.FindAllString(parseSlugAttrs(slug).Base, -1)
	max := 0
	for _, n := range nums {
		v, _ := strconv.Atoi(n)
		if v > max {
			max = v
		}
	}
	return max
}

func substituteSlug(e *Env, argv0, wanted, cliKind string) (string, error) {
	if cliKind == "claude" {
		if claudeSlugOK(wanted) {
			return wanted, nil
		}
	}
	rows := readCatalogRows(e.modelsTSV(argv0))
	if len(rows) == 0 {
		return wanted, nil
	}
	slugs := make([]string, 0, len(rows))
	for _, r := range rows {
		slugs = append(slugs, r.Slug)
		if r.Slug == wanted {
			return wanted, nil
		}
	}
	wf := familyOfSlug(e, wanted)
	wp := parseSlugAttrs(wanted)
	type cand struct {
		rank int
		fast int
		slug string
	}
	var sameBase []cand
	for _, s := range slugs {
		if familyOfSlug(e, s) != wf {
			continue
		}
		p := parseSlugAttrs(s)
		if p.Base != wp.Base {
			continue
		}
		f := 1
		if p.Fast == wp.Fast {
			f = 0
		}
		sameBase = append(sameBase, cand{rank: effortRank(wp.Effort, p.Effort), fast: f, slug: s})
	}
	if len(sameBase) > 0 {
		sort.Slice(sameBase, func(i, j int) bool {
			if sameBase[i].rank != sameBase[j].rank {
				return sameBase[i].rank < sameBase[j].rank
			}
			return sameBase[i].fast < sameBase[j].fast
		})
		picked := sameBase[0].slug
		if picked != wanted {
			fmt.Fprintf(os.Stderr, "[cmdp] routing: substituted %s → %s (same-base)\n", wanted, picked)
		}
		return picked, nil
	}
	var sameFam []string
	for _, s := range slugs {
		if familyOfSlug(e, s) == wf {
			sameFam = append(sameFam, s)
		}
	}
	if len(sameFam) > 0 {
		sort.Slice(sameFam, func(i, j int) bool {
			vi, vj := versionKey(sameFam[i]), versionKey(sameFam[j])
			if vi != vj {
				return vi > vj
			}
			pi, pj := parseSlugAttrs(sameFam[i]), parseSlugAttrs(sameFam[j])
			ri, rj := effortRank(wp.Effort, pi.Effort), effortRank(wp.Effort, pj.Effort)
			if ri != rj {
				return ri < rj
			}
			if pi.Fast != pj.Fast {
				return !pi.Fast && pj.Fast
			}
			return sameFam[i] < sameFam[j]
		})
		picked := sameFam[0]
		fmt.Fprintf(os.Stderr, "[cmdp] routing: substituted %s → %s (same-family)\n", wanted, picked)
		return picked, nil
	}
	prefer := strings.Split(modelsPreferCSV(e, cliKind), ",")
	for _, fam := range prefer {
		fam = strings.TrimSpace(fam)
		if fam == "" || fam == wf {
			continue
		}
		var pool []string
		for _, s := range slugs {
			if familyOfSlug(e, s) == fam {
				pool = append(pool, s)
			}
		}
		if len(pool) == 0 {
			continue
		}
		sort.Slice(pool, func(i, j int) bool {
			pi, pj := parseSlugAttrs(pool[i]), parseSlugAttrs(pool[j])
			ri, rj := effortRank(wp.Effort, pi.Effort), effortRank(wp.Effort, pj.Effort)
			if ri != rj {
				return ri < rj
			}
			if pi.Fast != pj.Fast {
				return !pi.Fast && pj.Fast
			}
			return pool[i] < pool[j]
		})
		picked := pool[0]
		fmt.Fprintf(os.Stderr, "[cmdp] routing: substituted %s → %s (prefer-family)\n", wanted, picked)
		return picked, nil
	}
	return "", usageError("no allowed catalog slug for role (wanted %s)", wanted)
}

func applyRubric(e *Env, role string, argv []string) ([]string, error) {
	if len(argv) == 0 {
		return argv, nil
	}
	argv0 := argv[0]
	kind, _ := cliKindReceipt(e, argv0)
	slug, rule := rubricPick(role, jobScope, jobRisk, kind)
	jobRule = rule
	newSlug, err := substituteSlug(e, argv0, slug, kind)
	if err != nil {
		return argv, err
	}
	return argvSetModel(argv, newSlug), nil
}

func policyCheck(e *Env, argv0, slug string) error {
	if slug == "" {
		return nil
	}
	kind, _ := cliKindReceipt(e, argv0)
	fam := familyOfSlug(e, slug)
	allow := modelsAllowCSV(e)
	if allow == "" {
		return usageError("empty allowlist")
	}
	if kind == "claude" && !claudeSlugOK(slug) {
		return usageError("claude kind accepts anthropic only (got %s)", slug)
	}
	if !csvHas(allow, fam) {
		return usageError("family %s not in allow=%s", fam, allow)
	}
	return nil
}

func nearestSlugs(e *Env, argv0, slug string) string {
	fam := familyOfSlug(e, slug)
	n := 0
	var out []string
	for _, r := range readCatalogRows(e.modelsTSV(argv0)) {
		if r.Family == fam {
			out = append(out, r.Slug)
			n++
			if n >= 8 {
				break
			}
		}
	}
	return strings.Join(out, " ")
}

func validateCatalog(e *Env, argv0, slug string) error {
	if slug == "" {
		return nil
	}
	if os.Getenv("CP_MODELS_VALIDATE") == "off" {
		return nil
	}
	kind, _ := cliKindReceipt(e, argv0)
	if kind == "claude" {
		if claudeSlugOK(slug) {
			return nil
		}
		return usageError("model slug '%s' is not a Claude alias or claude-* name", slug)
	}
	if !catalogExists(e, argv0) {
		fmt.Fprintf(os.Stderr, "[cmdp] models: no catalog for %s — slug not validated\n", argv0)
		return nil
	}
	if slugInCatalog(e, argv0, slug) {
		return nil
	}
	nearest := nearestSlugs(e, argv0, slug)
	if nearest != "" {
		return usageError("model slug '%s' not in %s catalog (nearest: %s)", slug, argv0, nearest)
	}
	return usageError("model slug '%s' not in %s catalog", slug, argv0)
}

func modelStatus(e *Env, argv0, slug string) string {
	kind, _ := cliKindReceipt(e, argv0)
	if slug == "" {
		return "unvalidated(no catalog)"
	}
	if kind == "claude" {
		if claudeSlugOK(slug) {
			return "static"
		}
		return "not-in-catalog"
	}
	if catalogStatus(e, argv0) == "none" {
		return "unvalidated(no catalog)"
	}
	if slugInCatalog(e, argv0, slug) {
		return "in-catalog"
	}
	return "not-in-catalog"
}

func announceRouting(e *Env, role, source, reason string, argv []string) {
	announceRoutingResolution(role, source, reason, argv)
	if len(argv) == 0 {
		return
	}
	slug := argvModel(argv)
	if slug == "" {
		return
	}
	fmt.Fprintf(os.Stderr, "[cmdp] routing: model=%s family=%s catalog=%s rule=%s\n",
		slug, familyOfSlug(e, slug), catalogStatus(e, argv[0]), jobRule)
}

func doctorModelsJSON(e *Env) map[string]any {
	out := map[string]any{}
	clis, _ := listSupportedCLIs(e)
	ttl := modelsTTL(e)
	now := time.Now().Unix()
	for _, argv0 := range clis {
		kind, _ := cliKindReceipt(e, argv0)
		meta := readMeta(e.modelsMeta(argv0))
		count := catalogCount(e, argv0)
		fetched := meta["fetched_at"]
		status := catalogStatus(e, argv0)
		stale := false
		static := kind == "claude" || meta["static"] == "true"
		if status == "stale" {
			stale = true
		}
		if epoch, err := strconv.ParseInt(meta["fetched_epoch"], 10, 64); err == nil && epoch > 0 && now-epoch > ttl && kind != "claude" && meta["status"] != "failed" {
			status = "stale"
			stale = true
		}
		out[argv0] = map[string]any{
			"count": count, "fetched_at": fetched,
			"status": status, "stale": stale, "static": static,
		}
	}
	return out
}

func printModelsUsage() {
	prog := os.Args[0]
	fmt.Fprintf(os.Stderr, "usage: %s models [--json] [--cli ARGV0] [--family F] [--all]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s models refresh [--quiet] [--cli ARGV0]\n", prog)
	fmt.Fprintf(os.Stderr, "       %s models check SLUG --cli ARGV0\n", prog)
	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "Cached per-CLI model catalog (data/models/<argv0>.tsv). Cursor CLIs\n")
	fmt.Fprintf(os.Stderr, "run ARGV0 models; Claude uses a static alias set. Allow-filtered by\n")
	fmt.Fprintf(os.Stderr, "default (--all shows blocked families). Slug check is fail-closed\n")
	fmt.Fprintf(os.Stderr, "only when a catalog exists. Env: CP_MODELS_ALLOW, CP_MODELS_TTL_SEC,\n")
	fmt.Fprintf(os.Stderr, "CP_MODELS_VALIDATE=off, CP_MODELS_CATALOG_CMD (tests).\n")
	os.Exit(2)
}

// CmdModels is bin/cmdp models.
func CmdModels(e *Env, args []string) error {
	jsonOut, quiet, all := false, false, false
	cli, family, action, slug := "", "", "list", ""
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--json":
			jsonOut = true
		case "--quiet":
			quiet = true
		case "--all":
			all = true
		case "--cli":
			if i+1 >= len(args) {
				return usageError("--cli needs ARGV0")
			}
			cli = args[i+1]
			i++
		case "--family":
			if i+1 >= len(args) {
				return usageError("--family needs F")
			}
			family = args[i+1]
			i++
		case "refresh":
			action = "refresh"
		case "check":
			if i+1 >= len(args) {
				return usageError("check needs SLUG")
			}
			action = "check"
			slug = args[i+1]
			i++
		case "-h", "--help":
			printModelsUsage()
			os.Exit(2)
		default:
			return usageError("unexpected arg %s", args[i])
		}
	}
	switch action {
	case "refresh":
		var names []string
		if cli != "" {
			names = []string{cli}
		} else {
			names, _ = listSupportedCLIs(e)
		}
		var first error
		for _, n := range names {
			if lookPath(n) == "" {
				continue
			}
			if err := modelsRefreshCLI(e, n, quiet); err != nil && first == nil {
				first = err
			}
		}
		return first
	case "check":
		if cli == "" {
			return usageError("check needs --cli ARGV0")
		}
		if slug == "" {
			return usageError("check needs SLUG")
		}
		modelsEnsureFresh(e, cli)
		if err := policyCheck(e, cli, slug); err != nil {
			return err
		}
		return validateCatalog(e, cli, slug)
	}
	var names []string
	if cli != "" {
		names = []string{cli}
	} else {
		names, _ = listSupportedCLIs(e)
	}
	if jsonOut {
		b, _ := json.Marshal(doctorModelsJSON(e))
		fmt.Println(string(b))
		return nil
	}
	allow := modelsAllowCSV(e)
	for _, n := range names {
		kind, _ := cliKindReceipt(e, n)
		st := catalogStatus(e, n)
		count := catalogCount(e, n)
		fmt.Printf("%s: %d slugs (%s)\n", n, count, st)
		var rows []catalogRow
		if kind == "claude" && len(readCatalogRows(e.modelsTSV(n))) == 0 {
			rows = []catalogRow{
				{Slug: "fable", Family: "anthropic", Display: "Claude alias"},
				{Slug: "opus", Family: "anthropic", Display: "Claude alias"},
				{Slug: "sonnet", Family: "anthropic", Display: "Claude alias"},
			}
		} else {
			rows = readCatalogRows(e.modelsTSV(n))
		}
		for _, r := range rows {
			if !all && !csvHas(allow, r.Family) {
				continue
			}
			if family != "" && r.Family != family {
				continue
			}
			fmt.Printf("  %s\t%s\t%s\n", r.Slug, r.Family, r.Display)
		}
	}
	return nil
}

func printDoctorModels(e *Env, clis []string) {
	fmt.Println("\nModels:")
	for _, name := range clis {
		if lookPath(name) == "" {
			continue
		}
		st := catalogStatus(e, name)
		count := catalogCount(e, name)
		fetched := readMeta(e.modelsMeta(name))["fetched_at"]
		if fetched != "" {
			fmt.Printf("  %s: %d slugs, fetched %s (%s)\n", name, count, fetched, st)
		} else {
			fmt.Printf("  %s: %d slugs (%s)\n", name, count, st)
		}
	}
	for _, role := range []string{"researcher", "implementer", "gate-reviewer"} {
		r := resolveRoleArgv(e, role)
		fmt.Printf("  %s model_status=%s\n", role, modelStatus(e, r.Argv0, argvModel(r.Argv)))
	}
}
