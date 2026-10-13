#!/usr/bin/env bash
# ***************
# Filename: run_sim.sh
# Author: FPGA Cores 4 U
# Description: Compile the firmware (sw/video_proc.py, which imports the CPU
#   initialisation sw/video_init.py -> build/fw/video_proc.*, pyc.py)
#   and run the video_processor system testbench with Icarus Verilog.
#   Sources: scripts/build.f then tb/scripts/build.f. Output goes to
#   build/sim. Fails unless the log contains TEST PASSED.
# Date: 2026-10-11
# ***************
# Usage: scripts/run_sim.sh [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>] [--lint] [--quick] [--ideal-pll]
#                           [--list-tests] [--gif=<file>] [--gif-bw] [--gif-frames=<n>]
#   --list-tests  print the name and description of each test the system
#            testbench runs (ip/scripts/list_tests.py), then exit; every run
#            also prints the test names at its start. The tests, in order:
#            test_boot, test_core_reset, test_firmware, test_vision_output,
#            test_hdmi, test_lvds, test_adapter, test_images, test_tracking,
#            test_uart_report
#   --gif=<file>  tracking test input: any animated GIF (also GIF_IN=<file>);
#            its size sets the tracking frame size (fitted to 320 x 240)
#   --gif-bw  convert a colour input GIF to black and white (BT.601 luma; the
#            converted GIF is saved as gif-input/<name>_bw.gif); without
#            it a colour GIF goes through the pipeline in colour
#   --gif-frames=<n>  send only the first n frames of the tracking GIF
#            (shorter run; default all 50)
#   --vcd    dump build/sim/video_processor_tb.vcd (+vcd). A whole run is long and
#            the dump large: --vcd-start / --vcd-stop limit it to a window of
#            simulated time (microseconds)
#   --wave   --vcd, then open the VCD in the Surfer waveform viewer (pass or fail)
#   --quick  sets the GPIO0[31] strap: the firmware skips the register dumps
#            of section 3 (CPU) and section 5 (every video_processor register),
#            about 3 hours less; the set-up write reports (old / new value) of
#            sections 4 and 8 still run.
#   --ideal-pll  compile with DPLL_IDEAL: the clock generator's PLLs are plain
#            clock toggles (clk = #delay ~clk) at the exact ratios instead of
#            the loop and oscillator models (much faster simulation) The UART 0 report is saved to build/sim/cpu_bootup.txt.
# Image test: input images are read from build/sim/input_images/ (the
#   testbench generates frame_c_<n>_input.ppm / frame_m_<n>_input.ppm there
#   when missing; put your own P5 / P6 files of the same names there to use
#   them), every module output image goes to build/sim/output_images/. Both
#   directories are created here (Icarus has no $system to create them).
# Tracking test: the input is tb/images/pedestrian_walk.gif (--gif=<file> or
#   GIF_IN=<file> to use another animated GIF; its size, fitted to 320 x 240,
#   is the tracking frame size the firmware programs;
#   colour is kept unless --gif-bw; regenerate the
#   default with tb/scripts/make_pedestrian_gif.py); the HDMI output with the
#   dashed tracking box is written to build/sim/gif-output/<name>_tracked.gif
#   (GIF outputs go to build/sim/gif-output/, the input sequence as sent to
#   build/sim/gif-input/<name>_<w>x<h>.gif).
# The simulation runs in a local work directory (SIM_WORK_DIR, default a new
#   directory under $TMPDIR): writing the report and images inside a cloud-
#   synced folder (OneDrive, iCloud, ...) slows the simulator down many
#   times. The results are copied back to build/sim at the end (also when
#   it fails or is interrupted); the work directory, printed at the start,
#   holds the live cpu_bootup.txt while it runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filelist() { grep -Ev '^\s*(#|$)' "$ROOT/$1" | sed "s#^#$ROOT/#"; }
VCD=0; WAVE=0; LINT=0; QUICK=0; VCDWIN=""; DEFS=""; GIFARGS=""
for a in "$@"; do
  case "$a" in
    --vcd) VCD=1;; --wave) VCD=1; WAVE=1;; --lint) LINT=1;; --quick) QUICK=1;;
    --ideal-pll) DEFS="$DEFS -DDPLL_IDEAL";;
    --list-tests) python3 "$ROOT/../../ip/scripts/list_tests.py" "$ROOT"; exit 0;;
    --gif-frames=*) GIFARGS="$GIFARGS +GIF_FRAMES=${a#--gif-frames=}";;
    --gif=*) GIF_IN="${a#--gif=}";;
    --gif-bw) GIFARGS="$GIFARGS +GIF_BW";;
    --vcd-start=*) VCDWIN="$VCDWIN +vcd_start_us=${a#--vcd-start=}";;
    --vcd-stop=*)  VCDWIN="$VCDWIN +vcd_stop_us=${a#--vcd-stop=}";;
    *) echo "unknown option $a"; exit 2;;
  esac
done
if [ -n "${GIF_IN:-}" ]; then                    # the simulation runs elsewhere: absolute path
  [ -f "$GIF_IN" ] || { echo "[video_processor] GIF not found: $GIF_IN"; exit 2; }
  GIF_IN="$(cd "$(dirname "$GIF_IN")" && pwd)/$(basename "$GIF_IN")"
fi
SRCS="$(filelist scripts/build.f | tr '\n' ' ')"
echo "[video_processor] tests: $(python3 "$ROOT/../../ip/scripts/list_tests.py" "$ROOT" --names | tr '\n' ' ')"
TB_SRCS="$(filelist tb/scripts/build.f | tr '\n' ' ')"
if [ "$LINT" = 1 ]; then
  verilator --lint-only -Wall -Wno-fatal --top-module video_processor $SRCS
fi
FW="$ROOT/build/fw"; mkdir -p "$FW"
python3 "$ROOT/../../ip/cpu/py_core/tools/pyc.py" -I "$ROOT/src" -I "$ROOT/../../ip/cpu/py_soc/src" -I "$ROOT/../../ip/video/video_pipeline/src" --code-aw 14 --str-slots 1024 --split-consts "$ROOT/sw/video_proc.py" -o "$FW/video_proc"
OUT="$ROOT/build/sim"; mkdir -p "$OUT" "$OUT/input_images" "$OUT/output_images" "$OUT/gif-output" "$OUT/gif-input"
WORK="${SIM_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/video_processor_sim.XXXXXX")}"
mkdir -p "$WORK/input_images" "$WORK/output_images" "$WORK/gif-output" "$WORK/gif-input"
cp -p "$OUT"/input_images/*.ppm "$WORK/input_images/" 2>/dev/null || true
rm -f "$WORK"/output_images/*.ppm "$WORK"/gif-output/*.gif "$WORK"/gif-input/*.gif
copy_back() {                                   # results -> build/sim
  cp -p "$WORK"/cpu_bootup.txt "$WORK"/video_processor_tb.log "$OUT/" 2>/dev/null || true
  cp -p "$WORK"/input_images/*.ppm "$OUT/input_images/" 2>/dev/null || true
  rm -f "$OUT"/output_images/*.ppm "$OUT"/gif-output/*.gif "$OUT"/gif-input/*.gif
  cp -p "$WORK"/output_images/*.ppm "$OUT/output_images/" 2>/dev/null || true
  cp -p "$WORK"/gif-output/*.gif "$OUT/gif-output/" 2>/dev/null || true
  cp -p "$WORK"/gif-input/*.gif "$OUT/gif-input/" 2>/dev/null || true
  cp -p "$WORK"/*.vcd "$OUT/" 2>/dev/null || true
  [ -n "${SIM_WORK_DIR:-}" ] || rm -rf "$WORK"
  if [ "$WAVE" = 1 ]; then                      # pass or fail
    if [ ! -f "$OUT/video_processor_tb.vcd" ]; then echo "[video_processor] no VCD written"
    elif command -v surfer >/dev/null 2>&1; then
      echo "[video_processor] opening $OUT/video_processor_tb.vcd in Surfer"
      nohup surfer "$OUT/video_processor_tb.vcd" > "$OUT/surfer.log" 2>&1 &
    else echo "surfer not found; install from https://surfer-project.org and open $OUT/video_processor_tb.vcd"; fi
  fi
}
trap copy_back EXIT
echo "[video_processor] simulating in $WORK (live report: $WORK/cpu_bootup.txt); results -> $OUT"
cd "$WORK"
iverilog -g2012 -Wall -Wno-timescale -s video_processor_tb -o video_processor_tb.vvp -I "$FW" -I "$ROOT/tb/tests" \
  -DFW_HEX="\"$FW/video_proc.flash.hex\"" $DEFS $SRCS $TB_SRCS
ARGS="+GIF_IN=${GIF_IN:-$ROOT/tb/images/pedestrian_walk.gif}$GIFARGS"
[ "$VCD" = 1 ] && ARGS="$ARGS +vcd$VCDWIN"; [ "$QUICK" = 1 ] && ARGS="$ARGS +quick"
vvp -n video_processor_tb.vvp $ARGS | tee video_processor_tb.log
grep -q "TEST PASSED" video_processor_tb.log || { echo "[video_processor] SIMULATION FAILED"; exit 1; }
echo "[video_processor] PASSED"
