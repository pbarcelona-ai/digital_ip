# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Single entry point for simulation, synthesis and documentation
#   of video_processor. Test targets fail on a bad result (ci/run_checked.sh),
#   not just a bad exit code.
# Date: 2026-10-11
# ***************
# Targets:
#   make help          this text
#   make sim           video_processor system test (Icarus): boot, camera -> ISP -> vision_system -> blur_sharpen -> tracker / overlay -> HDMI / LVDS, image test, tracking GIF
#   make wave          the system test with a VCD dump, opened in the Surfer waveform viewer (pass or fail)
#   make list-tests    name and description of every test the system test runs
#   make lint          Verilator lint of the RTL (warnings only)
#   make ip-test       the library video_pipeline system testbench (bit-exact ISP model, every output)
#   make synth         Yosys Xilinx 7-series synthesis -> build/yosys
#   make cov           sim + ip-test with Verilator code coverage -> build/coverage/summary.txt
#   make ci            sim + ip-test + synth
#   make diagram       re-render docs/*.dot -> .svg / .png (Graphviz)
#   make clean         remove build/ and ci/logs/
# Simulation options (sim, wave, cov; NAME=value on the make command line):
#   QUICK=1            skip the register dumps of sections 3 and 5 in the firmware report (GPIO0[31] strap): about 3 h faster; the set-up old / new value reports still run
#   IDEAL_PLL=1        clock generator PLLs as ideal clock toggles at the exact ratios (faster; PLL lock behaviour not modelled)
#   VCD=1              dump all signals to build/sim/video_processor_tb.vcd (large: use with a window)
#   VCD_START_US=<n>   start the VCD dump at n us of simulated time (VCD=1 or make wave)
#   VCD_STOP_US=<n>    stop the VCD dump at n us of simulated time (VCD=1 or make wave)
#   GIF=<file>         tracking test input: any animated GIF (default tb/images/pedestrian_walk.gif); its size sets the frame size (fitted to 320 x 240)
#   GIF_BW=1           convert a colour input GIF to black and white (BT.601 luma); without it a colour GIF runs through the pipeline in colour
#   GIF_FRAMES=<n>     send only the first n frames of the tracking GIF (shorter run; default every frame)
# Results (build/sim/): video_processor_tb.log, cpu_bootup.txt (UART 0 report), output_images/*.ppm,
#   gif-input/<name>_<w>x<h>.gif (the sequence as sent, plus <name>_bw.gif when converted),
#   gif-output/<name>_tracked.gif (HDMI output with the dashed tracking box)
# Examples:
#   make sim                                         full system test, default pedestrian GIF (long: every check, real PLL models)
#   make sim QUICK=1 IDEAL_PLL=1                     fastest full run
#   make sim QUICK=1 IDEAL_PLL=1 GIF_FRAMES=6        quick check of the tracking flow on the first 6 GIF frames
#   make sim GIF=$HOME/clips/walk.gif                track in your own GIF (colour stays colour)
#   make sim GIF=$HOME/clips/walk.gif GIF_BW=1       your own colour GIF, converted to black and white first
#   make sim VCD=1 VCD_START_US=2000 VCD_STOP_US=2200    waveforms of a 200 us window only
#   make wave QUICK=1 IDEAL_PLL=1 VCD_START_US=2000 VCD_STOP_US=2100    same, then open Surfer
#   make cov QUICK=1                                 coverage of the quick run
#   make sim GIF=../my_clips/street.gif GIF_FRAMES=20 QUICK=1    relative path (from this directory), first 20 frames
# Without make: scripts/run_sim.sh [--quick] [--ideal-pll] [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>]
#   [--gif=<file>] [--gif-bw] [--gif-frames=<n>] [--lint] [--list-tests]
# end of help

SHELL := /bin/bash
CHECK := ci/run_checked.sh
WINOPT := $(if $(VCD_START_US),--vcd-start=$(VCD_START_US),) $(if $(VCD_STOP_US),--vcd-stop=$(VCD_STOP_US),)
QOPT   := $(if $(filter 1,$(QUICK)),--quick,) $(if $(filter 1,$(IDEAL_PLL)),--ideal-pll,)
GOPT   := $(if $(GIF_FRAMES),--gif-frames=$(GIF_FRAMES),) $(if $(GIF),--gif=$(GIF),) $(if $(filter 1,$(GIF_BW)),--gif-bw,)
SIMOPT := $(if $(filter 1,$(VCD)),--vcd $(WINOPT),) $(QOPT) $(GOPT)

.PHONY: all help sim wave lint ip-test synth diagram ci cov clean list-tests
all: help
help:
	@sed -n '/^# Targets:/,/^# end of help/p' Makefile | sed -e '$$d' -e 's/^# \{0,1\}//'

list-tests:
	@python3 ../../ip/scripts/list_tests.py .

sim:
	@$(CHECK) sim 'TEST PASSED' 'TEST FAILED|ERROR' -- scripts/run_sim.sh $(SIMOPT)

wave:
	@scripts/run_sim.sh --wave $(WINOPT) $(QOPT) $(GOPT)

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
	dot -Tsvg docs/tracking_diagram.dot -o docs/tracking_diagram.svg
	dot -Tpng -Gdpi=110 docs/tracking_diagram.dot -o docs/tracking_diagram.png

ci: sim ip-test synth

cov:
	@../../ip/scripts/run_cov.sh build/coverage $(MAKE) --no-print-directory sim ip-test QUICK=$(QUICK)

clean:
	rm -rf build ci/logs
