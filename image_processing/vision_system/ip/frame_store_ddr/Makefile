# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Test and synthesis targets for frame_store_ddr
# Date: 2026-10-21
# ***************

SHELL := /bin/bash

.PHONY: all test wave synth clean help

help:
	@echo "frame_store_ddr targets:"
	@echo "  make test       Run cocotb tests (SMALL=1 by default)"
	@echo "  make test FULL=1   Run with full-size parameters"
	@echo "  make wave       Run tests with VCD dump and open in Surfer"
	@echo "  make synth      Run Yosys synthesis check"
	@echo "  make clean      Remove build artifacts"

test:
	@scripts/run.sh

wave:
	@WAVES=1 scripts/run.sh

synth:
	@echo "Synthesis check not yet implemented for frame_store_ddr"
	@exit 0

clean:
	@rm -rf tb/sim_build tb/work tb/__pycache__ scripts/__pycache__
	@find . -name '*.vvp' -delete
	@find . -name 'waves.vcd' -delete