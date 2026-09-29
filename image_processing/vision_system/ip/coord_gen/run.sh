#!/usr/bin/env bash
# Builds and runs coord_gen's self-checking testbench.
# Depends on barrel_pkg.sv and distortion_model_pkg.sv, in ../../src/,
# this project's shared package location, plus fixed_recip.sv (the
# MODEL_FISHEYE/MODEL_PANORAMIC/MODEL_PERSPECTIVE "slow path" instantiates
# it directly) and mulq_s.sv (the pipelined multiplier every multiply
# goes through), both in sibling ip/ directories.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 $DEFS -o tb_coord_gen.vvp \
  ../../src/barrel_pkg.sv ../../src/distortion_model_pkg.sv \
  ../fixed_recip/fixed_recip.sv ../mulq/mulq_s.sv \
  coord_gen.sv tb_coord_gen.sv
vvp tb_coord_gen.vvp

# Optional waveform viewing (see ../../synth/view_waves.sh): VCD=1 dumps
# waves.vcd; add SURFER=1 to open it in Surfer afterwards.
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../../synth/view_waves.sh waves.vcd
fi
