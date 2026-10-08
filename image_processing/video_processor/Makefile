# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Single entry point for simulation, synthesis and documentation
#   of video_processor. Test targets fail on a bad result (ci/run_checked.sh),
#   not just a bad exit code.
# Date: 2026-10-02
# ***************
# Common usage:
#   make sim       video_processor smoke test (Icarus Verilog)
#   make lint      Verilator lint of the RTL
#   make ip-test   full video_pipeline system testbench (library)
#   make synth     Yosys Xilinx 7-series synthesis -> build/yosys
#   make diagram   regenerate docs/*block_diagram.svg / .png (Graphviz)
#   make ci        sim + ip-test + synth
#   make clean
# Options: VCD=1 dump waveforms

SHELL := /bin/bash
CHECK := ci/run_checked.sh
SIMOPT := $(if $(filter 1,$(VCD)),--vcd,)

.PHONY: all help sim lint ip-test synth diagram ci clean
all: help
help:
	@sed -n "9,16p" Makefile

sim:
	@$(CHECK) sim 'TEST PASSED' 'TEST FAILED|ERROR' -- scripts/run_sim.sh $(SIMOPT)

lint:
	@scripts/run_sim.sh --lint

ip-test:
	@$(CHECK) video_pipeline 'TEST PASSED' 'TEST FAILED' -- $(MAKE) -C ../../ip/video/video_pipeline test

synth:
	@$(CHECK) synth 'SYNTH PASS' 'SYNTH FAIL' -- synth/run_yosys.sh

diagram:
	dot -Tsvg docs/block_diagram.dot -o docs/block_diagram.svg
	dot -Tpng -Gdpi=110 docs/block_diagram.dot -o docs/block_diagram.png
	dot -Tsvg docs/system_block_diagram.dot -o docs/system_block_diagram.svg
	dot -Tpng -Gdpi=100 docs/system_block_diagram.dot -o docs/system_block_diagram.png

ci: sim ip-test synth

clean:
	rm -rf build ci/logs
