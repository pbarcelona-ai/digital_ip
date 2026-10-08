#!/usr/bin/env bash
# ***************
# Filename: run_yosys.sh
# Author: FPGA Cores 4 U
# Description: Run the common Yosys Xilinx 7-series flow on one IP.
#   Sources come from <ip>/scripts/build.f, the flow is in
#   scripts/synth.ys and all results go to build/yosys/<ip>. An IP with a
#   scripts/sv2v marker file is converted with sv2v before Yosys reads it.
# Date: 2026-09-29
#
# Usage: scripts/run_yosys.sh <ip>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || { echo "usage: $0 <ip> [synthesis options]"; exit 2; }
IP="$1"; shift; lookup "$IP"
if [[ "$CAT" == scalers ]]; then
  exec "$REPO/scalers/$IP/scripts/synth.sh" "$@"
fi
[ $# -eq 0 ] || { echo "usage: $0 <ip>"; exit 2; }
command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }
BUILD_ROOT="${BUILD_ROOT:-$REPO/build}"
OUT="$BUILD_ROOT/yosys/$IP"; rm -rf "$OUT"; mkdir -p "$OUT"
if [ -f "$IPDIR/scripts/sv2v" ]; then
  # IP includes sources the Yosys SystemVerilog reader cannot parse (e.g. the
  # scaler family): convert the whole file list with sv2v first, as the
  # scaler flow does
  command -v sv2v >/dev/null || { echo "sv2v not found"; exit 1; }
  sv2v $(filelist "$IP") > "$OUT/$IP.sv2v.v"
  { echo "# generated from $CAT/$IP/scripts/build.f via sv2v"
    echo "read_verilog -sv $OUT/$IP.sv2v.v"
    echo "hierarchy -check -top $TOP"; } > "$OUT/read_design.ys"
else
{
  echo "# generated from $CAT/$IP/scripts/build.f"
  for f in $(filelist "$IP"); do echo "read_verilog -sv $f"; done
  echo "hierarchy -check -top $TOP"
} > "$OUT/read_design.ys"
fi
cd "$OUT"
yosys -l yosys.log -s "$REPO/scripts/synth.ys" > /dev/null || { tail -5 yosys.log; exit 1; }
# ltp sees module instances as combinational boxes, so the top entry is a
# false path; report leaf modules only.
grep -E "^Longest topological path in" logic_depth.rpt | grep -v " in $TOP " \
  | sed -E 's/\$paramod[^\\]*\\//' > logic_depth_summary.rpt || true
echo "[$IP] yosys done -> $OUT"
echo "  logic depth (coarse cells, per leaf module):"; sed 's/^/    /' logic_depth_summary.rpt
echo "  primitives (flat):"
PRIMITIVES="$(awk '
  $1 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $2 ~ /^[0-9]+$/ { print "  " $1 " " $2; next }
  $2 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $1 ~ /^[0-9]+$/ { print "  " $2 " " $1 }
' utilization_flat.rpt | tail -n 12)"
if [ -n "$PRIMITIVES" ]; then printf '%s\n' "$PRIMITIVES" | sed 's/^/    /'
else echo "    (no primitive cells reported)"; fi
