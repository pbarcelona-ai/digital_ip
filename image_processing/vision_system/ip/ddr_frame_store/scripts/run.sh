#!/usr/bin/env bash
# ***************
# Filename: run.sh
# Author: FPGA Cores 4 U
# Description: Builds and runs ddr_frame_store's self-checking testbench
#   (tb/tb_ddr_frame_store.sv) with the store on ddr_ctrl and ddr_mem.
#   VCD=1 dumps tb_ddr_frame_store.vcd; MUTATE=1 runs the mutation check
#   (the testbench must fail).
# Date: 2026-10-25
# ***************
# Usage: scripts/run.sh
set -e
cd "$(dirname "$0")/.."
L=../../../../ip
DEFS=""
[ "${MUTATE:-0}" = "1" ] && DEFS="-DMUTATE"
ARGS=""
[ "${VCD:-0}" = "1" ] && ARGS="+vcd"
iverilog -g2012 -Wall -Wno-timescale -I tb/tests $DEFS -s tb_ddr_frame_store -o tb_ddr_frame_store.vvp \
  $L/fifo/fallthrough_fifo/src/fallthrough_fifo.sv src/ddr_frame_store.sv \
  $L/shared/src/interfaces/regbus_if.sv $L/memory/ddr_ctrl/src/include/ddr_ctrl_regs_if.sv \
  $L/memory/ddr_ctrl/src/ddr_ctrl.sv $L/memory/ddr_mem/src/ddr_mem.sv tb/tb_ddr_frame_store.sv
vvp -n tb_ddr_frame_store.vvp $ARGS | tee tb_ddr_frame_store.log
grep -q "TEST PASSED" tb_ddr_frame_store.log
