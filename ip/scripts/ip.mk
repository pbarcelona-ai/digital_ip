IP_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
include $(IP_ROOT)/.tools
SIM ?= $(SIMULATOR)
PYTHON_SIM ?= $(PYTHON_SIMULATOR)
SYNTH_TOOL ?= $(SYNTHESIS)

.PHONY: all help test sim run yosys synth python-test docs diagrams diagram-check clean
all: help

help:
	@printf '%s\n' 'Targets: test (or sim), yosys (or synth), docs, diagrams, diagram-check, clean'

test sim run:
	@SIM="$(SIM)" PYTHON_SIM="$(PYTHON_SIM)" "$(IP_ROOT)/scripts/run_sim.sh" "$(IP)"

ifeq ($(SYNTH_TOOL),synplify)
synth:
	@SYNTH_TOOL="$(SYNTH_TOOL)" "$(IP_ROOT)/scripts/run_synplify.sh" "$(IP)"
else
synth:
	@"$(IP_ROOT)/scripts/run_yosys.sh" "$(IP)"
endif

yosys:
	@$(MAKE) synth IP=$(IP) SYNTH_TOOL=yosys

synplify:
	@$(MAKE) synth IP=$(IP) SYNTH_TOOL=synplify

docs:
	@python3 "$(IP_ROOT)/scripts/gen_docs.py"

diagrams:
	@python3 "$(IP_ROOT)/scripts/make_block_diagrams.py" "$(IP)"

diagram-check:
	@python3 "$(IP_ROOT)/scripts/make_block_diagrams.py" --check "$(IP)"

clean:
	@rm -rf "$(IP_ROOT)/build/sim/$(IP)" "$(IP_ROOT)/build/yosys/$(IP)"

python-test:
	@test -f "$(CURDIR)/tb/python/run_python.py" || { echo "no Python testbench configured for $(IP)" >&2; exit 2; }
	@PYTHON_SIM="$(PYTHON_SIM)" python3 "$(CURDIR)/tb/python/run_python.py"