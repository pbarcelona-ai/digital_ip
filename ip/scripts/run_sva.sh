#!/usr/bin/env bash
# ***************
# Filename: run_sva.sh
# Author: Paul Barcelona
# Description: Runs the concurrent SVA demonstration with Verilator
#   (assertions enabled). Lints the checkers first. Concurrent SVA is not
#   supported by iverilog 12 or Yosys 0.33, so this is the only place
#   they run. Usage - scripts/run_sva.sh. Output in build/sva.
# Date: 2026-09-29
set -e
cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=build/sva; mkdir -p $OUT
SRC="bus/axi4_lite_slave/src/axi4_lite_slave.sv bus/axi4_lite_regs/src/axi4_lite_regs.sv shared/src/fifo/ip_axis_fifo.sv bus/axi_stream_fifo/src/axi_stream_fifo.sv assertions/axis_protocol_checker.sv assertions/axil_protocol_checker.sv assertions/sva_demo_tb.sv"
verilator --lint-only -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE --timing $SRC --top-module sva_demo_tb 2>&1 | tail -5 || true
verilator --binary --assert --timing -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Mdir $OUT $SRC --top-module sva_demo_tb -o sva_demo > $OUT/build.log 2>&1 || { tail -20 $OUT/build.log; echo "[sva] BUILD FAILED"; exit 1; }
$OUT/sva_demo | tee $OUT/run.log
grep -q "TEST PASSED" $OUT/run.log && ! grep -q "%Error\|Assertion failed" $OUT/run.log && echo "[sva] PASSED" || { echo "[sva] FAILED"; exit 1; }
