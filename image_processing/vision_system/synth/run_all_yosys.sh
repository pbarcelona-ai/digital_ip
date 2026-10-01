#!/usr/bin/env bash
# ***************
# Filename: run_all_yosys.sh
# Author: FPGA Cores 4 U
# Description: Runs Yosys synthesis for every module directory (each with
# its own build.f + run_yosys.sh), estimates worst reg-to-reg timing for
# each with est_timing.py, and writes a combined table to
# synth/summary.md. Exits non-zero if any module has negative estimated
# slack at CLOCK_NS (default 10.0 = 100 MHz), so CI can gate on it.
# Date: September 26, 2026
# ***************
# Usage: synth/run_all_yosys.sh [module ...]     (default: all modules)
#        CLOCK_NS=8 synth/run_all_yosys.sh        (tighter target)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
CLOCK_NS="${CLOCK_NS:-10.0}"
MODULES=("${@:-ip/fixed_recip ip/mulq ip/frame_buffer ip/ext_frame_buffer ip/bilinear ip/bicubic ip/coord_gen src}")
# shellcheck disable=SC2206
MODULES=(${MODULES[@]})

OUT="$ROOT/synth/summary.md"
{
  echo "# Yosys synthesis summary (xc7, target ${CLOCK_NS} ns)"
  echo
  echo "| module | LUT | FF | DSP48E1 | RAMB36 | RAMB18 | SRL | est. worst path (ns) | est. slack (ns) | timing |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
} > "$OUT"

RC=0
for m in "${MODULES[@]}"; do
  echo "=== synthesizing $m ==="
  RUNNER="$ROOT/$m/scripts/run_yosys.sh"
  [ "$m" = src ] && RUNNER="$ROOT/scripts/run_yosys.sh"
  if ! "$RUNNER" > /tmp/run_yosys_$(basename "$m").log 2>&1; then
    echo "  SYNTHESIS FAILED (see /tmp/run_yosys_$(basename "$m").log)"
    echo "| $m | - | - | - | - | - | - | - | - | SYNTH FAIL |" >> "$OUT"
    RC=1; continue
  fi
  RPT="$ROOT/$m/yosys/utilization_hier.rpt"
  NET="$ROOT/$m/yosys/synth_netlist_flat.json"
  read -r -a R < <(python3 - "$RPT" << 'PY'
import sys; sys.path.insert(0, "synth")
import summarize as s
r = s.summary(sys.argv[1])
print(r['lut'], r['ff'], r['dsp'], r['bram36'], r['bram18'], r['srl'])
PY
)
  read -r WMOD DELAY SLACK < <(python3 synth/est_timing.py "$NET" "$CLOCK_NS" --brief)
  if python3 synth/est_timing.py "$NET" "$CLOCK_NS" --brief --strict >/dev/null; then
    T="MET"
  else
    T="**VIOLATED**"; RC=1
  fi
  echo "  ${R[*]} | worst=$WMOD ${DELAY}ns slack=${SLACK}ns $T"
  echo "| $m | ${R[0]} | ${R[1]} | ${R[2]} | ${R[3]} | ${R[4]} | ${R[5]} | $DELAY ($WMOD) | $SLACK | $T |" >> "$OUT"
done

{
  echo
  echo "Timing is a netlist-based **estimate** (synth/est_timing.py: explicit"
  echo "per-cell delay model on the FLATTENED netlist, no placement/routing), not Vivado STA."
} >> "$OUT"
echo; cat "$OUT"
exit $RC
