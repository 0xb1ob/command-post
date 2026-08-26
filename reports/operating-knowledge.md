# Operating knowledge absorbed from machine-local memory

Date: 2026-08-26
Issue: [command-post#78](https://github.com/0xb1ob/command-post/issues/78)
Contract: [AGENTS.md](../AGENTS.md)

Thirty entries lived in gitignored `data/learnings.md` where a fresh clone could
not see them. Rules now live in `AGENTS.md`; this note carries the *why* and
incident detail. Defects with open fix issues (#74–#77, muxa#121/#122) stay
tracked there — memory holds only the interim workaround until the contract or
tooling absorbs them.

## Parallel PRs from one base

Two PRs cut from the same base can each pass CI and still break `main` on the
second merge: branch CI tests the branch tip; `mergeable: MERGEABLE` only rules
out textual conflicts, not logical ones (e.g. one PR removes a test the sibling
just added). **Rule:** rebase the second PR onto the merged tip and re-run the
**full** suite before merge, or serialize the second dispatch behind the first
merge. Diagnose with `gh run list --branch main` — the first red SHA after a
green sibling merge names the bad second merge — not by reading diffs alone.

Evidence: muxa `main` red 2026-08-25; ssv-ops-dashboard #24+#25 both from
c2246b3, green at a8d8ca0 then red at 7b56b22.

## Teardown: merged PR, auto-deleted head branch

`bin/cp teardown` fail-closes with "branch has no upstream and is not on origin"
when the PR **merged** and GitHub auto-deleted the head branch — absence from
origin reads like never-pushed. **Do not trust** `git diff origin/main...branch`
after squash merge; the three-dot diff still shows the branch's own changes.

**Verify merged-and-absorbed:**

1. PR state `MERGED`
2. `git ls-remote --heads origin <branch>` empty
3. Two-dot tree diff empty: `git diff <branch> origin/main`

Then use the documented teardown fallback from outside the worktree:
`treehouse return --force`, `muxa kill`, `bin/cp jobs done`.

Evidence: command-post-gv7 / ethereum-staking-api #352.

## br list verification cap

br 0.2.19 default `--limit` is unlimited; older br defaulted to 50. Verification
paths in `bin/cp` pass `--limit 0` explicitly. When auditing manually, pass
`--limit 0` if the result decides membership or existence; `--limit 50` caps
at 50 and sets `has_more`. Fix tracked:
[command-post#74](https://github.com/0xb1ob/command-post/issues/74).

## Promote-not-spawn and occupancy

When `muxa who --json` shows an idle worker on the target worktree, promote with
`muxa send` — do not `muxa dispatch` again. `muxa dispatch --cwd` may warn the
path is occupied and still create a pane; the warning is not permission to
duplicate. `bin/cp check` fail-closes and names the remedy. New lease only after
return or for an independent job.

**Contradicting signals (workaround until #77 / muxa#121):** roster absence is
not proof of death. When `muxa dispatch` warns `cwd … already has live worker X`
while `who` omits X, believe the warning and `muxa tail X` before proceeding.

See also [dispatch-hardening.md](dispatch-hardening.md).

## First-brief receipt (kind-aware)

Broker bookkeeping is not proof of delivery. Cursor: one `muxa tail` for
`Branch: ${branch}`. Claude: footer `Context: N%` — immediate `0.0%` is
`unknown`, not failed (boot looks like a drop). Never grep the bare branch name
on claude panes (footer always shows branch → false positive; strict token →
false negative).

Evidence: five dispatches self-reported receipt while two had received nothing;
br command-post-6wco.

## Broker parent turns (opposite remedies)

Read the reason text — remedies differ:

| Shape | Wrong recovery |
| --- | --- |
| bare `[muxa] from=broker` | re-send into cold pane |
| `dispatch refused: … foreign input` | teardown (pane is healthy) |
| `dispatch unsubmitted:` | re-dispatch / re-lease |

The old `dispatch unconfirmed … pane still free` warning is gone as of muxa
1.0.12. Contract: AGENTS.md [Broker parent turns](../AGENTS.md#broker-parent-turns).

## Treehouse basename pools

Pools are keyed by repo **basename**; another checkout of the same name can
poison the pool on a project's **first** lease. At registration (not only
recovery): inspect `~/.treehouse/<basename>-*`, confirm `git-common-dir` matches
`projects/<name>/.git`, dry-run `treehouse destroy <pool> --all`, then re-lease.
Never `git worktree add` under `projects/.worktrees/`. See
[dispatch-hardening.md](dispatch-hardening.md#2-stale-clone--belongs-to-another-repo).

## Manual lease fallback (#76)

`treehouse get --lease` keys off cwd, not a path argument — never pass
`projects/<name>` as an arg. Use `bin/cp lease --project NAME` (cd into the
canonical clone first). If `bin/cp` itself is unavailable: `cd projects/<name>`
then `treehouse get --lease`; always follow with `bin/cp check --project NAME
"$worktree"`. See [dispatch-hardening.md](dispatch-hardening.md#2-stale-clone--belongs-to-another-repo).

## Bind the leased path

Bind `treehouse get --lease` output to a variable; pass it to `bin/cp check` and
dispatch — never retype. `bin/cp dispatch` mechanizes lease-bind when available.

## Fan-out and alias collisions

Dispatch commands sequentially or pass `--name`; parallel `muxa dispatch` can
assign the same alias.

## Parent turn latency

While the parent pane is busy the broker holds worker mail — batching many merges
delays every report. Late duplicate `[muxa]` turns after a delivery fix are
historical; check pending mail, sender registration, and PR/br state before
re-investigating a repeat.

## muxa upgrade (one binary + daemon)

Upgrading muxa is: stop daemon, replace binary, restart, confirm `muxa version`
(tag+sha). Never copy over a running binary on macOS (invalidated signature →
SIGKILL). Upgrade only with an **idle fleet** — daemon restart reassigns the
parent alias and re-indexes pane ids; live children keep a dead parent name.
Consumers fail closed on **shape**, never exit status alone.

## Cross-repo breaking changes

When a worker declares a breaking change to a surface another repo consumes,
verify against the live consumer **before** merge. A worker's LOUD note enables
that check — act on it.

Evidence: muxa#48 `who --json` shape vs command-post `bin/cp check`.

## Gate policy nuances

Branch on `cause`, not prose. `operational` → retry same model once; second
`operational` → `operational_persistent` / swap model. `policy` → caller.
Escalate is not always "research failed": read reasons — `blocking_unknowns` can
force escalate while the write-up is strong (research succeeded, work
undispatchable). Structural-only defects (missing sections) → revise and
re-gate, not operator escalate.

Commission falsifying fixtures **before** deleting a safety net — muxa#43's
cursor-idle vs cursor-typed proved half-typed composer invisible to two-signal
detection, so #45 was re-sequenced behind #46.

## delivery:pr hold

After `jobs reported`, keep worker and lease until CI and automated review
settle — findings are promote (`muxa send`), not fresh lease. Wait with bounded
`gh pr checks N --watch`; workers may exit after reporting so promote is not
guaranteed.

## Automated review: defect vs remedy

Reviewers can be right about the defect and wrong about the fix (one PR's diff,
no sibling context). Relay **problem + verified current truth** to workers; require
dispute-in-writing, not silent omission.

## Research: bounded artifacts and cross-repo checks

- Closed upstream tracker ≠ proof a route shipped; frontend "blocked" ≠ proof
  backend missing — check both against code.
- Cross-repo: one researcher per repo, bounded TSV (`capability|endpoint|status|evidence`
  and `phase|feature|state|wait-class|evidence`); parent reads TSV directly.
- Ask OPEN QUESTIONS as a second block (`unknown|blocks|why|evidence`).
- Parallel workers on one domain: each states shared assumptions with citations;
  "unverified" is valid; "naturally safe" without citation is not.
- Grain mismatch: confirm the question's unit exists before answering in it.

## Status block: re-derive blockers

Re-verify every Blocked row each turn — a blocked list is a claim, not state to
copy. Human decisions belong in Awaiting you only. Same-base merge hazard means
**rebase before merge**, not unnecessary serialization. Tool refusal ≠ impossibility —
use the documented manual path when appropriate.

## Parent never does the worker job

A request naming a model or capability never licenses bypassing dispatch. The
compliant path is `bin/cp dispatch ... -- claude --model …` (or routed CLI), not
in-session subagents for the work itself.

## CI triage: local-green / CI-red

Same suite total with CI red / local green → suspect race or environment, not
missing deps. Reproduce on `origin/main` in isolation before weakening tests.
Spurious pass streaks prove nothing; high-volume repro for rare flakes. Typical
fix: move assertion inside the same `waitFor` after async flush.

## Artifact dir vs mirror (#75)

`artifact add` mirrors one file; `teardown` drops the whole dir — second files
(e.g. `summary.tsv`) are lost silently. Copy extras out before teardown until
[#75](https://github.com/0xb1ob/command-post/issues/75) lands.

## muxa parent orphan recovery (#122)

Killed/restarted parent orphans workers (`parent=<dead-alias>`; mail is
parent↔child only). Recovery: `muxa register --name <dead-alias> --kind claude`
from the new pane; `muxa tail` is read-only fallback. `jobs.tsv` survives
(keyed by br id). Tracked: muxa#122.

## Broker pending/ mailbox

Read broker `pending/` JSON to recover undelivered worker reports; `attempts=0`
means never delivered (re-send); `attempts>0` means arrived (safe to clear).
Clearing `attempts=0` drops mail a busy worker still needs.

## Operator discipline

- Verify rendering against the **data source** before filing a display bug
  (`muxa who`, theme tokens).
- macOS `/bin/bash` is 3.2 — fractional `read -t`, `declare -A`, `${x^^}` fail;
  Ubuntu CI will not catch. Probe that always errors makes its guard fail silently.
- Caller "blocked by #N" may be a PR number — check `gh pr view` and `gh issue view`.
