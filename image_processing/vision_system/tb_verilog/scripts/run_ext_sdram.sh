#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
# Optional waveform viewing: VCD=1 dumps waves.vcd; SURFER=1 opens it (../synth/view_waves.sh).
DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 -I tests $DEFS -s tb_ext_sdram -o work/tb_ext_sdram.vvp \
  ../include/barrel_pkg.sv ../include/distortion_model_pkg.sv tb_ext_sdram.sv \
  ../ip/fixed_recip/src/fixed_recip.sv ../ip/mulq/src/mulq_s.sv \
  ../ip/coord_gen/src/coord_gen.sv ../ip/bilinear/src/bilinear.sv ../ip/bicubic/src/bicubic.sv \
  ../ip/frame_buffer/src/frame_buffer.sv ../ip/ext_frame_buffer/src/ext_frame_buffer.sv \
  ../src/axis_in_ctrl.sv ../src/axis_out_ctrl.sv ../src/axi_lite_regs.sv \
  ../src/vision_system.sv
vvp work/tb_ext_sdram.vvp
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../synth/view_waves.sh waves.vcd
fi