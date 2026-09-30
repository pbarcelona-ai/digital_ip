#!/usr/bin/env bash
# ***************
# Filename: run_all.sh
# Author: Paul Barcelona
# Description: Run simulation and selected synthesis for every IP listed
#   in scripts/ips.csv and print a pass/fail summary table.
# Date: 2026-09-29
#
# Usage: scripts/run_all.sh [sim|yosys|synplify|both]
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
MODE="${1:-both}"; FAIL=0
case "$MODE" in sim|yosys|synplify|both) ;; *) echo "usage: $0 [sim|yosys|synplify|both]"; exit 2 ;; esac
BUILD_ROOT="${BUILD_ROOT:-$REPO/build}"
export BUILD_ROOT
SCALER_OUTDIR="${SCALER_OUTDIR:-$BUILD_ROOT/scaler}"
mkdir -p "$BUILD_ROOT"
RUN_SIM=1; RUN_SYNTH=1; SYNTH_BACKEND="$SYNTH_TOOL"
case "$MODE" in
  sim) RUN_SYNTH=0 ;;
  yosys) RUN_SIM=0; SYNTH_BACKEND=yosys ;;
  synplify) RUN_SIM=0; SYNTH_BACKEND=synplify ;;
  both) ;;
esac
printf "%-24s %-6s %-8s\n" IP SIM SYNTH
while IFS=, read -r ip category _; do
  if [[ -z "$ip" || "$ip" == \#* ]]; then continue; fi
  if [[ "$category" == scalers && "$SYNTH_BACKEND" != synplify ]]; then continue; fi
  S="-"; Y="-"
  if [ "$RUN_SIM" = 1 ] && [[ "$category" != scalers ]]; then
    "$SCRIPT_DIR/run_sim.sh" "$ip" > "$BUILD_ROOT/sim_$ip.log" 2>&1 && S=PASS || { S=FAIL; FAIL=1; }
  fi
  if [ "$RUN_SYNTH" = 1 ] && [ "$SYNTH_BACKEND" = synplify ]; then
    "$SCRIPT_DIR/run_synplify.sh" "$ip" > "$BUILD_ROOT/synplify_$ip.log" 2>&1 && Y=PASS || { Y=FAIL; FAIL=1; }
  elif [ "$RUN_SYNTH" = 1 ]; then
    "$SCRIPT_DIR/run_yosys.sh" "$ip" > "$BUILD_ROOT/yosys_$ip.log" 2>&1 && Y=PASS || { Y=FAIL; FAIL=1; }
  fi
  printf "%-24s %-6s %-8s\n" "$ip" "$S" "$Y"
done < "$SCRIPT_DIR/ips.csv"
if [ "$RUN_SIM" = 1 ]; then
  echo "Running standalone scaler IP regression"
  SIM="$SIM" MODE="${SCALER_MODE:-frame}" VCD="${SCALER_VCD:-0}" SCALER_OUTDIR="$SCALER_OUTDIR" \
    "$REPO/tools/run_all.sh" || FAIL=1
fi
if [ "$RUN_SYNTH" = 1 ] && [ "$SYNTH_BACKEND" = yosys ]; then
  echo "Synthesizing standalone scaler IPs"
  "$REPO/tools/synth_all.sh" || FAIL=1
fi
exit "$FAIL"
