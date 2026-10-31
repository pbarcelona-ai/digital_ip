#!/usr/bin/env bash
# ***************
# Filename: run_yosys.sh
# Author: FPGA Cores 4 U
# Description: Yosys Xilinx 7-series synthesis of video_processor. The
#   sources (scripts/build.f) are read with the yosys-slang front end
#   (read_slang: the SystemVerilog as written, one compilation unit; sv2v
#   would inline every module with interface ports into one 34k-line module
#   that Yosys's own front end needs hours for). Results go to build/yosys
#   (utilization_flat.rpt, utilization_hier.rpt, netlist.v).
#   Technology independent: no I/O buffers, PLL or D-PHY are inferred.
#   vision_system is built with its frames in the DDR (VS_USE_DDR_FB, the
#   default; the on-chip option needs 4 x 720 x 720 x 24 bits, about 50
#   Mbit); symbol_overlay's smooth-font ROMs come from its src/include
#   (OVL_FONT_DIR). By default the NPU is synthesised with an 8 x 8 MAC
#   array and without the library flow's longest-path report and opt -full
#   (the 64 x 64 array is 64 times the same PE; the full run needs more than
#   the 8 GB of a laptop): SYNTH_FULL=1 runs ip/scripts/synth.ys on the
#   design as built (NPU_PE 64). The default flow maps LUTs with classic ABC
#   (synth_xilinx's map_luts step with abc -lut 6 in place of abc9): ABC9's
#   timing-driven mapping of the whole flattened design
#   (about 2.9 M AND gates in one network) ran for more than 12 hours; the
#   IP-level library flows keep ABC9.
# Date: 2026-10-27
# ***************
# Usage: synth/run_yosys.sh            (SYNTH_FULL=1 synth/run_yosys.sh: the library flow, NPU_PE 64)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLOW="$ROOT/../../ip/scripts/synth.ys"
command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }
OUT="$ROOT/build/yosys"; rm -rf "$OUT"; mkdir -p "$OUT"
FULL="${SYNTH_FULL:-0}"
PE=8; [ "$FULL" = 1 ] && PE=64
SRCS="$(grep -Ev '^\s*(#|$)' "$ROOT/scripts/build.f" | sed "s#^#$ROOT/#" | tr '\n' ' ')"
{ echo "# generated from scripts/build.f (yosys-slang)"
  echo "read_slang --single-unit --unroll-limit=200000 -D SYNTHESIS -G NPU_PE=$PE -G OVL_FONT_DIR=\"$ROOT/../../ip/video/symbol_overlay/src/include/\" --top video_processor $SRCS"
  echo "hierarchy -check -top video_processor"
  } > "$OUT/read_design.ys"
if [ "$FULL" = 1 ]; then
  SCRIPT="$FLOW"
else
  SCRIPT="$OUT/synth_lite.ys"
  cat > "$SCRIPT" <<EOF
script read_design.ys
proc
opt_expr
opt_clean
check -assert
tee -o pre_synth.rpt stat
synth_xilinx -family xc7 -noiopad -noclkbuf -run :map_luts
opt_expr -mux_undef -noclkinv
abc -lut 6
clean
xilinx_srl -fixed -minlen 3
techmap -map +/xilinx/lut_map.v -map +/xilinx/cells_map.v -D LUT_WIDTH=6
xilinx_dffopt
opt_lut_ins -tech xilinx
synth_xilinx -family xc7 -noiopad -noclkbuf -run finalize:
opt_clean -purge
check
tee -o utilization_hier.rpt stat -tech xilinx -width
tee -o utilization_flat.rpt stat -tech xilinx
write_verilog -noattr netlist.v
EOF
fi
cd "$OUT"
yosys -m slang -l yosys.log -s "$SCRIPT" > /dev/null || { tail -5 yosys.log; echo "SYNTH FAIL"; exit 1; }
echo "[video_processor] yosys done -> $OUT (NPU_PE $PE)"
echo "  primitives (flat):"
awk '$1 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $2 ~ /^[0-9]+$/ { print "    " $1 " " $2 }
     $2 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $1 ~ /^[0-9]+$/ { print "    " $2 " " $1 }' utilization_flat.rpt
echo "SYNTH PASS"
