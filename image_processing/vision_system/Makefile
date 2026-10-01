# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Single entry point for simulation and synthesis, used by
# both developers and the GitHub Actions workflow. Every test target
# fails on a bad result (see ci/run_checked.sh), not just a bad exit code.
# Date: September 26, 2026
# ***************
# Common usage:
#   make test-ip        standalone IP testbenches (fast)
#   make test-smoke     coord_gen smoke test (fast)
#   make test-sv        top-level SystemVerilog regression, SMALL frames
#   make test-ext-sdram top-level SDRAM frame-buffer smoke test
#   make test-cocotb    top-level cocotb regression, SMALL frames
#   make sim            all of the above
#   make synth          Yosys synthesis + timing estimate, every module
#   make html           build the local HTML documentation site
#   make ci             sim + synth
#   make diagram        regenerate docs/block_diagram.svg/.png
# Options:  FULL=1  use full-size frames (480x480/480x720/720x480; hours)
#           VCD=1   dump waveforms   SURFER=1  (with VCD=1) open Surfer

SHELL := /bin/bash
CHECK := ci/run_checked.sh
IPS   := fixed_recip frame_buffer ext_frame_buffer mulq bilinear bicubic coord_gen

ifeq ($(FULL),1)
SV_ENV :=
CT_ENV :=
else
SV_ENV := SMALL=1
CT_ENV := SMALL_FRAMES=1
endif

.PHONY: all sim ci test-ip test-smoke test-sv test-ext-sdram test-cocotb synth html diagram clean help
all: help
help:
	@sed -n "9,19p" Makefile

test-ip:
	@for d in $(IPS); do \
	  $(CHECK) ip-$$d '>>> PASS <<<' 'FAIL' -- ip/$$d/scripts/run.sh || exit 1; \
	done

test-smoke:
	@$(CHECK) smoke 'SMOKE TEST PASSED' 'SMOKE TEST FAILED' -- tb_verilog/scripts/run_smoke.sh

test-sv:
	@$(CHECK) sv-regression 'ALL SELF-CHECKS PASSED' 'SELF-CHECK FAILURE' -- env $(SV_ENV) tb_verilog/scripts/run.sh

test-ext-sdram:
	@$(CHECK) ext-sdram '>>> PASS <<<' 'FAIL' -- tb_verilog/scripts/run_ext_sdram.sh

test-cocotb:
	@$(CHECK) cocotb 'TESTS=3 PASS=3 FAIL=0' - -- env $(CT_ENV) python3 tb/scripts/run.py

sim: test-ip test-smoke test-sv test-ext-sdram test-cocotb

synth:
	@status=0; $(CHECK) synth 'Yosys synthesis summary' 'VIOLATED|SYNTH FAIL' -- synth/run_all_yosys.sh || status=$$?; \
	  python3 docs/build_html.py; exit $$status

html:
	@python3 docs/build_html.py

ci: sim synth

diagram:
	python3 docs/make_block_diagram.py

clean:
	rm -rf ci/logs synth/summary.md
	find . -name '*.vvp' -delete
	find . -name yosys -type d -prune -exec rm -rf {} +
	rm -rf tb/sim_build tb/work tb_verilog/work tb_verilog/work_small
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
	find . -name waves.vcd -delete
