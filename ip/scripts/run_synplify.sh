#!/usr/bin/env bash
# Invoke a client-specific Synplify project wrapper for one catalog IP.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 1 ] || { echo "usage: $0 <ip>" >&2; exit 2; }
IP="$1"; lookup "$IP"
SYNPLIFY_RUNNER="${SYNPLIFY_RUNNER:-}"
if [[ -z "$SYNPLIFY_RUNNER" ]]; then
  echo "Synplify selected, but .tools/SYNPLIFY_RUNNER needs a client-specific wrapper path." >&2
  exit 2
fi
command -v "$SYNPLIFY_RUNNER" >/dev/null || [[ -x "$SYNPLIFY_RUNNER" ]] || {
  echo "Synplify wrapper not executable: $SYNPLIFY_RUNNER" >&2; exit 2;
}
if [[ "$CAT" == scalers ]]; then
  IP_DIR="$REPO/scalers/$IP"
  MANIFEST="$IP_DIR/src/build.f"
else
  IP_DIR="$IPDIR"
  MANIFEST="$IP_DIR/scripts/build.f"
fi
OUT="${BUILD_ROOT:-$REPO/build}/synplify/$CAT/$IP"
mkdir -p "$OUT"
export IP IP_CATEGORY="$CAT" IP_TOP="$TOP" IP_DIR IP_MANIFEST="$MANIFEST" IP_OUT="$OUT"
"$SYNPLIFY_RUNNER" "$IP_DIR" "$TOP" "$MANIFEST" "$OUT"