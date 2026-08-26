# br `--slug` and install

## Problem

`AGENTS.md` intake documents `br create … --slug <short> --json`. Older `br`
binaries on PATH rejected `--slug` (`unexpected argument '--slug'`), while
`bin/install.sh` skipped install when any `br` was present — stale homebrew or
manual installs never upgraded.

## Truth (br 0.2.19+)

`br create --help` lists `--slug`; it embeds a normalized slug in the generated
id (e.g. `command-post-survey-my-thing-<hash>`). The AGENTS example is correct
for current `br`.

## Fix

`install_br()` now upgrades when `br create --help` lacks `--slug`. `bin/cp
doctor` fails closed with the same signal. Re-run `bin/install.sh` on machines
that still have a pre-slug `br`.

No version pin in the contract — the documented command must work after install.
