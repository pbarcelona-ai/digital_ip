#!/usr/bin/env bash
# Usage: tools/run_iverilog.sh <dir_name> [plusargs...]
# Convenience wrapper: runs <dir_name>/run.sh (Icarus Verilog) with the given
# options. See <dir_name>/run.sh --help. Results go to <dir_name>/sim_out/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="$1"; shift
exec "$ROOT/scalers/$IP/run.sh" "$@"
