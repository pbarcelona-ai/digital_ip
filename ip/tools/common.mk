SCALER_ROOT ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
include $(SCALER_ROOT)/.tools
IP ?= all
SIM ?= $(SIMULATOR)
PYTHON_SIM ?= $(PYTHON_SIMULATOR)
SYNTH_TOOL ?= $(SYNTHESIS)
MODE ?= frame
VCD ?= 0
RUN_ARGS ?=
SYNTH_ARGS ?=
GATESIM_ARGS ?=
DIAGRAM_IPS ?=
DIAGRAM_ARGS ?=

IP_MODULES := axi_checkers axil_regbus axil_split banked_framebuf \
	scaler_anisotropic scaler_bicubic scaler_bilinear scaler_ctrl scaler_dda \
	scaler_edge_directed scaler_lanczos scaler_mip scaler_nearest scaler_polyphase \
	scaler_trilinear sharpen_cas spatial_upscaler

.PHONY: all help list test run sim synth synplify gatesim docs diagrams diagram-check clean
all: help

help:
	@printf '%s\n' \
	  'Targets: test, sim, synth, synplify, gatesim, docs, diagrams, diagram-check, clean, list' \
	  'Per-IP: make -C scalers/scaler_bicubic test|sim|synth|gatesim|clean' \
	  'Common:  make test [IP=scaler_bicubic] [MODE=frame|pingpong|linebuf]' \
	  '         make sim [IP=scaler_bicubic] [RUN_ARGS="+IMG=photo.ppm"]' \
	  '         make synth [IP=scaler_bicubic] [SYNTH_ARGS="-p MAX_W=1920"]' \
	  '         make gatesim IP=scaler_bicubic [GATESIM_ARGS="+QUICK"]' \
	  '         make diagrams [DIAGRAM_IPS="scaler_bilinear scaler_lanczos"] [DIAGRAM_ARGS="--dot-only"]'

list:
	@printf '%s\n' $(IP_MODULES)

docs:
	@python3 "$(SCALER_ROOT)/tools/generate_docs.py"
	@python3 "$(SCALER_ROOT)/scripts/package_ips.py"

diagrams:
	@python3 "$(SCALER_ROOT)/tools/docs/make_block_diagrams.py" $(DIAGRAM_IPS) $(DIAGRAM_ARGS)

diagram-check:
	@python3 "$(SCALER_ROOT)/tools/docs/make_block_diagrams.py" --check

ifeq ($(IP),all)
test:
	@SIM=$(SIM) MODE=$(MODE) VCD=$(VCD) $(SCALER_ROOT)/tools/run_all.sh $(RUN_ARGS)

sim:
	@SIM=$(SIM) MODE=$(MODE) VCD=$(VCD) $(SCALER_ROOT)/tools/run_all.sh $(RUN_ARGS)

ifeq ($(SYNTH_TOOL),synplify)
synth:
	@set -e; for module in $(IP_MODULES); do SYNTH_TOOL=synplify "$(SCALER_ROOT)/scripts/run_synplify.sh" "$$module"; done
else
synth:
	@$(SCALER_ROOT)/tools/synth_all.sh -- $(SYNTH_ARGS)
endif

clean:
	@for module in $(IP_MODULES); do \
	  rm -rf "$(SCALER_ROOT)/scalers/$$module/sim_out" "$(SCALER_ROOT)/scalers/$$module/yosys"; \
	done
	@rm -rf "$(SCALER_ROOT)/build/scaler"
else
test:
	@NO_VIEW=1 SIM=$(SIM) MODE=$(MODE) $(SCALER_ROOT)/tools/run_all.sh $(IP) $(RUN_ARGS)

sim:
	@NO_VIEW=1 SIM=$(SIM) MODE=$(MODE) $(SCALER_ROOT)/tools/run_all.sh $(IP) $(RUN_ARGS)

ifeq ($(SYNTH_TOOL),synplify)
synth:
	@SYNTH_TOOL=synplify "$(SCALER_ROOT)/scripts/run_synplify.sh" "$(IP)"
else
synth:
	@test -x "$(SCALER_ROOT)/scalers/$(IP)/scripts/synth.sh" || { echo "$(IP) has no synthesis flow" >&2; exit 2; }
	@"$(SCALER_ROOT)/scalers/$(IP)/scripts/synth.sh" $(SYNTH_ARGS)
endif

gatesim:
	@test -x "$(SCALER_ROOT)/scalers/$(IP)/scripts/synth.sh" || { echo "$(IP) has no gate-simulation flow" >&2; exit 2; }
	@$(SCALER_ROOT)/tools/gatesim.sh $(IP) $(GATESIM_ARGS)

clean:
	@rm -rf "$(SCALER_ROOT)/scalers/$(IP)/sim_out" "$(SCALER_ROOT)/scalers/$(IP)/yosys" "$(SCALER_ROOT)/build/scaler/$(IP)"
endif

run: test

synplify:
	@set -e; for module in $(IP_MODULES); do SYNTH_TOOL=synplify "$(SCALER_ROOT)/scripts/run_synplify.sh" "$$module"; done
