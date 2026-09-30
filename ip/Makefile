IP ?= all
MODE ?= frame
RUN_ARGS ?=
SCALER_IPS := axi_checkers axil_regbus axil_split banked_framebuf scaler_anisotropic scaler_bicubic scaler_bilinear scaler_ctrl scaler_dda scaler_edge_directed scaler_lanczos scaler_mip scaler_nearest scaler_polyphase scaler_trilinear sharpen_cas spatial_upscaler

.PHONY: all help test sim yosys gatesim docs diagrams diagram-check module-support scaler-test scaler-docs scaler-diagrams
all: help

help:
	@printf '%s\n' 'Full regression: '
	@printf '%s\n' '    make test [MODE=frame|pingpong|linebuf]'
	@printf '%s\n' 'One IP: '
	@printf '%s\n' '    make test IP=<name>; '
	@printf '%s\n' 'synthesis/gate sim: '
	@printf '%s\n' '    make yosys|gatesim [IP=<name>]'
	@printf '%s\n' 'Documentation: '
	@printf '%s\n' '    make docs'
	@printf '%s\n' 'diagrams: '
	@printf '%s\n' '    make diagrams [IP=<name>]'
	@printf '%s\n' 'Scaler-only: '
	@printf '%s\n' '    make scaler-test|scaler-docs|scaler-diagrams'

ifneq ($(filter $(IP),$(SCALER_IPS)),)
test:
	@NO_VIEW=1 SIM=iverilog MODE=$(MODE) ./tools/run_all.sh "$(IP)" $(RUN_ARGS)

sim:
	@NO_VIEW=1 SIM=verilator MODE=$(MODE) ./tools/run_all.sh "$(IP)" $(RUN_ARGS)

yosys:
	@./scalers/$(IP)/scripts/synth.sh

gatesim:
	@NO_VIEW=1 ./tools/gatesim.sh "$(IP)"

diagrams:
	@python3 ./tools/docs/make_block_diagrams.py "$(IP)"

diagram-check:
	@python3 ./tools/docs/make_block_diagrams.py --check "$(IP)"
else ifeq ($(IP),all)
test sim:
	@BUILD_ROOT="$(CURDIR)/build/regression" SCALER_OUTDIR="$(CURDIR)/build/regression/scaler" SCALER_MODE=$(MODE) ./scripts/run_all.sh sim

yosys:
	@./scripts/run_all.sh yosys

gatesim:
	@echo 'Select a scaler module with IP=<name> for gate-level simulation.' >&2
	@exit 2

diagrams:
	@python3 ./scripts/make_block_diagrams.py
	@python3 ./tools/docs/make_block_diagrams.py $(DIAGRAM_IPS) $(DIAGRAM_ARGS)

diagram-check:
	@python3 ./scripts/make_block_diagrams.py --check
	@python3 ./tools/docs/make_block_diagrams.py --check
else
test sim:
	@./scripts/run_sim.sh "$(IP)"

yosys:
	@./scripts/run_yosys.sh "$(IP)"

gatesim:
	@echo 'Gate-level simulation is available for scaler IPs only.' >&2
	@exit 2

diagrams:
	@python3 ./scripts/make_block_diagrams.py "$(IP)"

diagram-check:
	@python3 ./scripts/make_block_diagrams.py --check "$(IP)"
endif

docs:
	@python3 ./scripts/gen_docs.py
	@python3 ./tools/generate_docs.py

module-support:
	@python3 ./scripts/gen_module_support.py

scaler-test:
	@SIM=iverilog MODE=$(MODE) ./tools/run_all.sh

scaler-docs:
	@python3 ./tools/generate_docs.py

scaler-diagrams:
	@python3 ./tools/docs/make_block_diagrams.py