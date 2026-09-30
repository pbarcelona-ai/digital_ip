#!/usr/bin/env bash
# Invoke a client-specific Vivado synthesis/place-and-route Tcl project hook.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 1 ] || { echo "usage: $0 <ip>" >&2; exit 2; }
IP="$1"; lookup "$IP"
PNR_TOOL="${PNR_TOOL:-${PLACE_ROUTE:-}}"
if [[ "$PNR_TOOL" != vivado ]]; then
  echo "Vivado P&R is not selected; configure PLACE_ROUTE=vivado in .tools." >&2
  exit 2
fi
VIVADO_TCL="${VIVADO_TCL:-}"
if [[ -z "$VIVADO_TCL" || ! -f "$VIVADO_TCL" ]]; then
  echo "Set VIVADO_TCL to the client-specific project Tcl script in .tools or the environment." >&2
  exit 2
fi
VIVADO_BIN="${VIVADO_BIN:-vivado}"
command -v "$VIVADO_BIN" >/dev/null || { echo "Vivado not found (set VIVADO_BIN)" >&2; exit 2; }
if [[ "$CAT" == scalers ]]; then
  IP_DIR="$REPO/scalers/$IP"
  MANIFEST="$IP_DIR/src/build.f"
else
  IP_DIR="$IPDIR"
  MANIFEST="$IP_DIR/scripts/build.f"
fi
OUT="${BUILD_ROOT:-$REPO/build}/vivado/$CAT/$IP"
mkdir -p "$OUT"
export IP IP_CATEGORY="$CAT" IP_TOP="$TOP" IP_DIR IP_MANIFEST="$MANIFEST" IP_OUT="$OUT"
"$VIVADO_BIN" -mode batch -source "$VIVADO_TCL" -tclargs "$IP_DIR" "$TOP" "$MANIFEST" "$OUT"