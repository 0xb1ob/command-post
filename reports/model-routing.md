# Per-job model rubric

Contract: [AGENTS.md Model routing](../AGENTS.md#model-routing).
Allowlist, catalog, and `--scope`/`--risk` live in `bin/cmdp`; this table is the
transcribable pick. `data/routing.tsv` role rows skip it (operator pin).
`-- CMD` is rule 0 (family still must be in `allow`).

Inputs: `role` (researcher|implementer|gate-reviewer), `kind` (research|ship),
`delivery` (unused by the pick), `scope` (S|M|L, default S), `risk` (low|high,
default low), `cli` kind (`cursor`|`claude`), cached catalog, `allow`.

First match wins. Gate stays cursor-only in `bin/cmdp gate`; Claude column for
gate-reviewer is for doctor / a future hop, not a gate argv0 rewrite.

| # | Rule | Criteria | cursor kind | claude kind |
| --- | --- | --- | --- | --- |
| 0 | Caller override | `-- CMD` given | as given; family in `allow`; slug in catalog when one exists | same |
| 1 | Gate operational retry | role=gate-reviewer AND prior cause=operational_persistent | `cursor-grok-4.6-high-fast` | n/a (gate is cursor-only today) |
| 2 | Gate reviewer (normal) | role=gate-reviewer | `composer-2.5-fast` | `sonnet` (if gate ever runs on Claude) |
| 3 | Research, ambiguous/design | role=researcher AND scope=L | `cursor-grok-4.6-xhigh` | `claude-fable-5` (fable high; never sonnet) |
| 4 | Research, bounded | role=researcher, scope S/M | `cursor-grok-4.6-high-fast` | `fable` (never sonnet) |
| 5 | Risky ship | role=implementer AND risk=high | `cursor-grok-4.6-high` | `opus` |
| 6 | Small ship | role=implementer AND scope=S AND risk=low | `composer-2.5-fast` | `sonnet` |
| 7 | Medium/large ship | role=implementer AND scope∈{M,L} AND risk=low | `cursor-grok-4.6-high` | `opus` |
| 8 | Fallback | anything else | first catalog slug in `prefer.<kind>` order, preferring `-high` and non-`fast` | `sonnet` |

Tie-breakers when a named slug is missing from a **present** catalog:
(a) same family, same base, nearest effort (`high` → `xhigh` → `medium`);
(b) same family, newest base version; (c) next family in `prefer.<kind>`;
(d) fail closed exit 2. Each downgrade prints
`[cmdp] routing: substituted X → Y (reason)`.

No catalog (offline / first run): print
`[cmdp] models: no catalog for ARGV0 — slug not validated` and proceed.
`CP_MODELS_VALIDATE=off` skips membership even when a catalog exists.
Claude kind with a non-Anthropic slug always exits 2.

Rule 1 (gate retry model) is documented here; wiring a configurable retry
model and gate argv0 rewrite is out of this change.
