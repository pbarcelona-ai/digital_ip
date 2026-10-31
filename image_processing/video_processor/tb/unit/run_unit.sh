#!/usr/bin/env bash
# ***************
# Filename: run_unit.sh
# Author: FPGA Cores 4 U
# Description: Runs a unit test of a block written for this design (tb/unit/<name>_tb.sv) with Icarus
#   Verilog. Usage: tb/unit/run_unit.sh <name> (ddr_cpu_bridge, axil_core_gate); exit 0 on PASS, 1 on FAIL.
#   Work files in build/unit/.
# Date: 2026-10-26
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DESIGN="$(cd "$HERE/../.." && pwd)"
IP="$DESIGN/../../ip"
NAME="${1:?usage: run_unit.sh <name>}"
case "$NAME" in
  ddr_cpu_bridge) SRC=("$IP/shared/src/interfaces/axil_if.sv" "$DESIGN/src/ddr_cpu_bridge.sv");;
  axil_core_gate) SRC=("$IP/shared/src/interfaces/axil_if.sv" "$DESIGN/src/axil_core_gate.sv");;
  *) echo "run_unit.sh: unknown unit $NAME (ddr_cpu_bridge, axil_core_gate)"; exit 2;;
esac
WORK="$DESIGN/build/unit"
mkdir -p "$WORK"
iverilog -g2012 -Wall -o "$WORK/$NAME.vvp" -s "${NAME}_tb" "${SRC[@]}" "$HERE/${NAME}_tb.sv"
vvp -n "$WORK/$NAME.vvp" | tee "$WORK/$NAME.log"
grep -q "^PASS" "$WORK/$NAME.log"
