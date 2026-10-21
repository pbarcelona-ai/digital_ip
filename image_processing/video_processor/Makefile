# ***************
# Filename: Makefile
# Author: FPGA Cores 4 U
# Description: Single entry point for simulation, synthesis and documentation
#   of video_processor. Test targets fail on a bad result (ci/run_checked.sh),
#   not just a bad exit code.
# Date: 2026-10-14
# ***************
# Targets:
#   make help          this text
#   make sim           video_processor system test (Icarus): boot, camera -> ISP -> vision_system -> blur_sharpen -> tracker / overlay -> HDMI / LVDS, image test, tracking GIF
#   make pysim         the system test on the Python models (each IP's model/, from scripts/build.f; testbench pysim/): firmware on the py_core model, py_soc, video blocks, testbench;
#                      every real-life input in tb/images (or GIF=...) -> python-prototype/<name>_pysim.gif / .mp4 / _transcript.txt / _log.txt
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
#   GIF=<a>,<b>,...    several GIFs sent one after the other in one run (boot and image test once; every block set up again per GIF)
#   GIF_BW=1           convert a colour input GIF to black and white (BT.601 luma); without it a colour GIF runs through the pipeline in colour
#   GIF_FRAMES=<n>     send only the first n frames of the tracking GIF (shorter run; default every frame)
#   GIF_FIRST=<n>      start at frame n of the GIF (0 = the first): with GIF_FRAMES, a long GIF run in parts side by side (results <name>_from<n>)
#   GIF=<video>        a camera video (MP4, MOV, MKV, WebM) instead: tb/scripts/mp4_io.py (PyAV: python3 -m pip install av) samples it into the GIF
#                      the testbench sends (fitted to 320 x 240); the tracked output is also build/sim/video-output/<name>_tracked.mp4
#   VIDEO_FPS=<f>      frames per second taken from a video (default 10)
#   VIDEO_START=<s>    start time in a video, seconds (default 0)
#   SELECT=<what>      what to detect: 1 / pedestrians, 2 / faces, 3 / vehicles (cars, buses, trucks, planes); comma separated
#   DETECT=<classes>   object classes to detect and track: pedestrian, face, automobile (car), vehicle (bus, truck), comma separated, or all (default pedestrian)
#   BOX=<style>        box round every tracked object: dashed-box, solid-box, dashed-circle, solid-circle, dashed-oval, solid-oval,
#                      solid-centre (a solid box in the middle of the target; default for automobiles and vehicles, dashed-box for
#                      pedestrians and faces)
#   BOX=<class>:<style>,...   a style per class, e.g. BOX=face:solid-circle,car:dashed-box (other classes keep the default)
#   TARGETS=<n>        most targets tracked at any time, all classes together (1-12, default 12; up to 3 per class)
#   DIRECT_LOG=1       direct transcript: only the tracking (search / track lines, overlay boxes, summary) is written, straight
#                      to the transcript file through a GPIO port instead of UART 0 (much faster); register dumps skipped
# Box colours: pedestrian green, face magenta, automobile cyan, vehicle orange (one detector per class, up to 3 boxes per class).
# Detection: colour, edges and motion (feature_detect: Sobel edges, motion against a per-cell background, camera shift estimate).
# Results (build/sim/): sim_transcript_<GIF name>.txt (the report, written line by line while the simulation runs;
#   several GIFs: sim_transcript_<name>+<name>...txt and each GIF's tracking in sim_transcript_<GIF name>.txt),
#   video_processor_tb.log, output_images/*.ppm,
#   gif-input/<name>_<w>x<h>.gif (the sequence as sent, plus <name>_bw.gif when converted),
#   gif-output/<name>_tracked.gif (HDMI output with the tracking boxes)
#   video-output/<name>_tracked.mp4 (a video input's tracked output, H.264)
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
#   make sim QUICK=1 IDEAL_PLL=1 GIF=tb/images/street_scene.gif DETECT=all    every class (pedestrian, face, car, bus) in the test street
#   make sim QUICK=1 IDEAL_PLL=1 GIF=tb/images/bouncing-ricochets.gif DETECT=car,vehicle BOX=solid-circle    cars and buses, solid circles
#   make sim QUICK=1 IDEAL_PLL=1 DETECT=pedestrian,face BOX=pedestrian:solid-box,face:dashed-circle    a style per class
#   make sim IDEAL_PLL=1 DIRECT_LOG=1 DETECT=all TARGETS=6 GIF=tb/images/street_scene.gif,tb/images/go-fast.gif    two GIFs, 6 targets, fast transcript
#   make sim QUICK=1 IDEAL_PLL=1 DIRECT_LOG=1 DETECT=all GIF=tb/images/clip.mp4 VIDEO_START=2 GIF_FRAMES=20    2 s of a video from 2 s, 10 fps
# pysim options: GIF, GIF_FRAMES, GIF_FIRST, GIF_BW, VIDEO_FPS, VIDEO_START, DETECT (+ aircraft; default all), BOX (+ corner-box,
#   tick-box, triangle; default people corner-box, ground transport tick-box, aircraft triangle), TARGETS (1-15), DIRECT_LOG,
#   QUICK=0 (whole start-up report), JOBS=<n> inputs in parallel (default 4), PYSIM_OUT=<dir> (default python-prototype)
#   make pysim                                       every real-life video and GIF in tb/images (not the generated ones), 4 at a time
#   make pysim GIF=tb/images/airbus-plane.gif GIF_FRAMES=10    one input, its first 10 frames
# Without make: scripts/run_sim.sh [--quick] [--ideal-pll] [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>]
#   [--gif=<file>[,<file>...]] [--gif-bw] [--gif-frames=<n>] [--detect=<classes>] [--box=<style>|<class>:<style>,...]
#   [--targets=<n>] [--direct-log] [--video-fps=<f>] [--video-start=<s>] [--select=<what>] [--lint] [--list-tests]
# end of help

SHELL := /bin/bash
CHECK := ci/run_checked.sh
WINOPT := $(if $(VCD_START_US),--vcd-start=$(VCD_START_US),) $(if $(VCD_STOP_US),--vcd-stop=$(VCD_STOP_US),)
QOPT   := $(if $(filter 1,$(QUICK)),--quick,) $(if $(filter 1,$(IDEAL_PLL)),--ideal-pll,)
GOPT   := $(if $(GIF_FRAMES),--gif-frames=$(GIF_FRAMES),) $(if $(GIF_FIRST),--gif-first=$(GIF_FIRST),) $(if $(GIF),--gif=$(GIF),) $(if $(filter 1,$(GIF_BW)),--gif-bw,) \
          $(if $(DETECT),--detect=$(DETECT),) $(if $(SELECT),--select=$(SELECT),) $(if $(BOX),--box=$(BOX),) $(if $(TARGETS),--targets=$(TARGETS),) \
          $(if $(filter 1,$(DIRECT_LOG)),--direct-log,) $(if $(VIDEO_FPS),--video-fps=$(VIDEO_FPS),) $(if $(VIDEO_START),--video-start=$(VIDEO_START),)
SIMOPT := $(if $(filter 1,$(VCD)),--vcd $(WINOPT),) $(QOPT) $(GOPT)
comma  := ,
PYOPT  := $(if $(GIF_FRAMES),--frames $(GIF_FRAMES),) $(if $(GIF_FIRST),--gif-first $(GIF_FIRST),) $(if $(filter 1,$(GIF_BW)),--gif-bw,) \
          $(if $(DETECT),--detect $(DETECT),) $(if $(BOX),--box $(BOX),) $(if $(TARGETS),--targets $(TARGETS),) \
          $(if $(filter 1,$(DIRECT_LOG)),--direct-log,) $(if $(VIDEO_FPS),--video-fps $(VIDEO_FPS),) \
          $(if $(VIDEO_START),--video-start $(VIDEO_START),) $(if $(filter 0,$(QUICK)),--full,) \
          --jobs $(or $(JOBS),4) $(if $(PYSIM_OUT),--out $(PYSIM_OUT),) $(subst $(comma), ,$(GIF))

.PHONY: all help sim pysim wave lint ip-test synth diagram ci cov clean list-tests
all: help
help:
	@sed -n '/^# Targets:/,/^# end of help/p' Makefile | sed -e '$$d' -e 's/^# \{0,1\}//'

list-tests:
	@python3 ../../ip/scripts/list_tests.py .

sim:
	@$(CHECK) sim 'TEST PASSED' 'TEST FAILED|ERROR' -- scripts/run_sim.sh $(SIMOPT)

pysim:
	@python3 pysim/run_pysim.py $(PYOPT)

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
	dot -Tsvg docs/software_flow.dot -o docs/software_flow.svg
	dot -Tpng -Gdpi=100 docs/software_flow.dot -o docs/software_flow.png
	dot -Tpng -Gdpi=100 docs/reset_diagram.dot -o docs/reset_diagram.png
	dot -Tsvg docs/tracking_diagram.dot -o docs/tracking_diagram.svg
	dot -Tpng -Gdpi=110 docs/tracking_diagram.dot -o docs/tracking_diagram.png

ci: sim ip-test synth

cov:
	@../../ip/scripts/run_cov.sh build/coverage $(MAKE) --no-print-directory sim ip-test QUICK=$(QUICK)

clean:
	rm -rf build ci/logs
