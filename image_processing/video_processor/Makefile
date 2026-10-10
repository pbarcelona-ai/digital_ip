# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Single entry point for simulation, synthesis and documentation
#   of video_processor. Test targets fail on a bad result (ci/run_checked.sh),
#   not just a bad exit code.
# Date: 2026-10-02
# ***************
# Common usage:
#   make sim       video_processor system test (Icarus Verilog)
#   make wave      system test with the VCD dump, opened in the Surfer viewer
#   make lint      Verilator lint of the RTL
#   make ip-test   full video_pipeline system testbench (library)
#   make synth     Yosys Xilinx 7-series synthesis -> build/yosys
#   make diagram   regenerate docs/*block_diagram, clock_ / reset_diagram .svg / .png (Graphviz)
#   make ci        sim + ip-test + synth
#   make cov       sim + ip-test with Verilator code coverage -> build/coverage/summary.txt
#   make clean
# Options: VCD=1 dump waveforms (build/sim/video_processor_tb.vcd)
#          QUICK=1 skip the register dumps (faster)
#          VCD_START_US=<n> VCD_STOP_US=<n> dump only that window of simulated time

SHELL := /bin/bash
CHECK := ci/run_checked.sh
WINOPT := $(if $(VCD_START_US),--vcd-start=$(VCD_START_US),) $(if $(VCD_STOP_US),--vcd-stop=$(VCD_STOP_US),)
QOPT   := $(if $(filter 1,$(QUICK)),--quick,)
SIMOPT := $(if $(filter 1,$(VCD)),--vcd $(WINOPT),) $(QOPT)

.PHONY: all help sim wave lint ip-test synth diagram ci cov clean
all: help
help:
	@sed -n "9,22p" Makefile

sim:
	@$(CHECK) sim 'TEST PASSED' 'TEST FAILED|ERROR' -- scripts/run_sim.sh $(SIMOPT)

wave:
	@scripts/run_sim.sh --wave $(WINOPT) $(QOPT)

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
	dot -Tsvg docs/clock_diagram.dot -o docs/clock_diagram.svg
	dot -Tpng -Gdpi=100 docs/clock_diagram.dot -o docs/clock_diagram.png
	dot -Tsvg docs/reset_diagram.dot -o docs/reset_diagram.svg
	dot -Tpng -Gdpi=100 docs/reset_diagram.dot -o docs/reset_diagram.png

ci: sim ip-test synth

cov:
	@../../ip/scripts/run_cov.sh build/coverage $(MAKE) --no-print-directory sim ip-test QUICK=$(QUICK)

clean:
	rm -rf build ci/logs
