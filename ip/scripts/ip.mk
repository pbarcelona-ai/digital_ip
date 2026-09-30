IP_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)

.PHONY: all help test sim run yosys synth docs diagrams diagram-check clean
all: help

help:
	@printf '%s\n' 'Targets: test (or sim), yosys (or synth), docs, diagrams, diagram-check, clean'

test sim run:
	@"$(IP_ROOT)/scripts/run_sim.sh" "$(IP)"

yosys synth:
	@"$(IP_ROOT)/scripts/run_yosys.sh" "$(IP)"

docs:
	@python3 "$(IP_ROOT)/scripts/gen_docs.py"

diagrams:
	@python3 "$(IP_ROOT)/scripts/make_block_diagrams.py" "$(IP)"

diagram-check:
	@python3 "$(IP_ROOT)/scripts/make_block_diagrams.py" --check "$(IP)"

clean:
	@rm -rf "$(IP_ROOT)/build/sim/$(IP)" "$(IP_ROOT)/build/yosys/$(IP)"