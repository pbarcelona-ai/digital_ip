#!/usr/bin/env bash
# ***************
# Filename: run_yosys.sh
# Author: FPGA Cores 4 U
# Description: Yosys Xilinx 7-series synthesis of video_processor with the
#   library's common flow (ip/scripts/synth.ys). The scaler sources need
#   sv2v, so scripts/build.f is converted to Verilog first. Results go to
#   build/yosys (utilization_flat.rpt, utilization_hier.rpt, netlist.v).
#   Technology independent: no I/O buffers, PLL or D-PHY are inferred.
#   vision_system is built with its SDRAM frame buffer (VS_USE_EXT_FB = 1):
#   the on-chip option needs 4 x 720 x 720 x 24 bits (about 50 Mbit).
# Date: 2026-10-02
# ***************
# Usage: synth/run_yosys.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW="$ROOT/../../ip/scripts/synth.ys"
command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }
command -v sv2v  >/dev/null || { echo "sv2v not found"; exit 1; }
OUT="$ROOT/build/yosys"; rm -rf "$OUT"; mkdir -p "$OUT"
sv2v -DSYNTHESIS $(grep -Ev '^\s*(#|$)' "$ROOT/scripts/build.f" | sed "s#^#$ROOT/#") > "$OUT/video_processor.sv2v.v"
{ echo "# generated from scripts/build.f via sv2v"
  echo "read_verilog -sv $OUT/video_processor.sv2v.v"
  echo "chparam -set VS_USE_EXT_FB 1 video_processor"
  echo "hierarchy -check -top video_processor"; } > "$OUT/read_design.ys"
cd "$OUT"
yosys -l yosys.log -s "$FLOW" > /dev/null || { tail -5 yosys.log; echo "SYNTH FAIL"; exit 1; }
echo "[video_processor] yosys done -> $OUT"
echo "  primitives (flat):"
awk '$1 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $2 ~ /^[0-9]+$/ { print "    " $1 " " $2 }
     $2 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $1 ~ /^[0-9]+$/ { print "    " $2 " " $1 }' utilization_flat.rpt
echo "SYNTH PASS"
