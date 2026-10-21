#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p work
# Optional waveform viewing: VCD=1 dumps waves.vcd; SURFER=1 opens it (../synth/view_waves.sh).
DEFS=""
[ "${VCD:-0}" = "1" ] && DEFS="-DDUMP_VCD"

iverilog -g2012 -I tests $DEFS -s tb_ext_sdram -o work/tb_ext_sdram.vvp \
  ../include/barrel_pkg.sv ../include/distortion_model_pkg.sv ../../../ip/shared/src/interfaces/axis_if.sv ../../../ip/shared/src/interfaces/axil_if.sv ../../../ip/shared/src/interfaces/regbus_if.sv ../src/include/vision_system_regs_if.sv tb_ext_sdram.sv \
  ../ip/fixed_recip/src/fixed_recip.sv ../ip/mulq/src/mulq_s.sv \
  ../ip/coord_gen/src/coord_gen.sv ../ip/bilinear/src/bilinear.sv ../ip/bicubic/src/bicubic.sv \
  ../ip/frame_buffer/src/frame_buffer.sv ../ip/ext_frame_buffer/src/ext_frame_buffer.sv \
  ../../../ip/fifo/fallthrough_fifo/src/fallthrough_fifo.sv ../src/axis_in_ctrl.sv ../src/axis_out_ctrl.sv ../../../ip/bus/axi4_lite_slave/src/axi4_lite_slave.sv ../src/include/vision_system_regs.sv ../src/axi_lite_regs.sv \
  ../src/vision_system.sv
vvp work/tb_ext_sdram.vvp
if [ "${VCD:-0}" = "1" ] && [ "${SURFER:-0}" = "1" ]; then
  ../synth/view_waves.sh waves.vcd
fi