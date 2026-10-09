# py_soc: its own flow (compile the self-test firmware, then simulate), scripts/run_test.sh
#   make test [VCD=1]   simulate; VCD=1 also dumps build/sim/py_soc/py_soc_tb.vcd
#   make wave           simulate with the VCD dump and open it in the Surfer waveform viewer
VCD ?= 0

test sim:
	@scripts/run_test.sh $(if $(filter 1,$(VCD)),--vcd,)

wave:
	@scripts/run_test.sh --wave

.PHONY: test sim wave
