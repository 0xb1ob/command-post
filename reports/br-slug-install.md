# br `--slug`, pin, and install

## Problem

`AGENTS.md` intake documents `br create … --slug <short> --json`. Two separate
failure modes existed:

1. **Pre-slug binaries** — older `br` rejected `--slug`; `bin/install.sh`
   skipped install when any `br` was on PATH.
2. **Unpinned float-to-latest** — once `--slug` existed on 0.2.19, install
   skipped upgrade while `curl … install.sh` floated to `releases/latest`. A
   machine could land on br 0.5.2 (schema 17) against a schema-16 home tracker;
   every `bin/cp status` then died on `SCHEMA_MISMATCH` stdout.

## Truth

- `--slug` exists on **both** br 0.2.19 and 0.5.2 — it is **not** a version or
  schema gate.
- Latest stable pin for command-post is **v0.5.2** (`bin/install.sh` passes
  `--version v0.5.2`).
- Skip install only when PATH `br` is 0.5.2 **and**
  `br --db <home>/.beads/beads.db list --json` exits 0.
- Schema 16→17 is explicit: `br doctor migrate-schema plan` then
  `apply --plan-token`. No auto-migrate on ordinary commands.

## Fix

`install_br()` pins v0.5.2 and gates on `list --json` against the home tracker,
not on `--slug`. After install, if the home `.beads` exists and `list --json`
still fails, install prints the migrate-schema path and exits non-zero.

`bin/cp` rejects `{error:…}` on br `--json` stdout before normalizing list or
comments output.

Re-run `bin/install.sh` after pulling this change; migrate the live tracker
before expecting `bin/cp status` to work.

## br 0.5.x contract notes

- `br show --json` returns a JSON **array of one** issue with comments inlined;
  never use it for artifact bodies — use `bin/cp artifact get` / `br comments list`.
- In `--json` mode, structured errors (`SCHEMA_MISMATCH`, etc.) print on **stdout**
  as `{"error":{...}}` with non-zero exit — `bin/cp` rejects them before
  normalizing list/blocked/comments output.
