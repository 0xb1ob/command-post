#!/usr/bin/env bash
# Backward-compat shim — delegates to bin/install.sh (deps + scaffold).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$ROOT/bin/install.sh" "$@"
