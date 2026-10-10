#!/usr/bin/env bash
# ***************
# Filename: run_sim.sh
# Author: FPGA Cores 4 U
# Description: Compile the firmware (sw/video_proc.py, which imports the CPU
#   initialisation sw/video_init.py -> build/fw/video_proc.*, pyc.py)
#   and run the video_processor system testbench with Icarus Verilog.
#   Sources: scripts/build.f then tb/scripts/build.f. Output goes to
#   build/sim. Fails unless the log contains TEST PASSED.
# Date: 2026-10-08
# ***************
# Usage: scripts/run_sim.sh [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>] [--lint] [--quick] [--ideal-pll]
#   --vcd    dump build/sim/video_processor_tb.vcd (+vcd). A whole run is long and
#            the dump large: --vcd-start / --vcd-stop limit it to a window of
#            simulated time (microseconds)
#   --wave   --vcd, then open the VCD in the Surfer waveform viewer (pass or fail)
#   --quick  sets the GPIO0[31] strap: the firmware skips the CPU and video
#            register dumps (faster).
#   --ideal-pll  compile with DPLL_IDEAL: the clock generator's PLLs are plain
#            clock toggles (clk = #delay ~clk) at the exact ratios instead of
#            the loop and oscillator models (much faster simulation) The UART 0 report is saved to build/sim/cpu_bootup.txt.
# Image test: input images are read from build/sim/input_images/ (the
#   testbench generates frame_c_<n>_input.ppm / frame_m_<n>_input.ppm there
#   when missing; put your own P5 / P6 files of the same names there to use
#   them), every module output image goes to build/sim/output_images/. Both
#   directories are created here (Icarus has no $system to create them).
# The simulation runs in a local work directory (SIM_WORK_DIR, default a new
#   directory under $TMPDIR): writing the report and images inside a cloud-
#   synced folder (OneDrive, iCloud, ...) slows the simulator down many
#   times. The results are copied back to build/sim at the end (also when
#   it fails or is interrupted); the work directory, printed at the start,
#   holds the live cpu_bootup.txt while it runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filelist() { grep -Ev '^\s*(#|$)' "$ROOT/$1" | sed "s#^#$ROOT/#"; }
VCD=0; WAVE=0; LINT=0; QUICK=0; VCDWIN=""; DEFS=""
for a in "$@"; do
  case "$a" in
    --vcd) VCD=1;; --wave) VCD=1; WAVE=1;; --lint) LINT=1;; --quick) QUICK=1;;
    --ideal-pll) DEFS="$DEFS -DDPLL_IDEAL";;
    --vcd-start=*) VCDWIN="$VCDWIN +vcd_start_us=${a#--vcd-start=}";;
    --vcd-stop=*)  VCDWIN="$VCDWIN +vcd_stop_us=${a#--vcd-stop=}";;
    *) echo "unknown option $a"; exit 2;;
  esac
done
SRCS="$(filelist scripts/build.f | tr '\n' ' ')"
TB_SRCS="$(filelist tb/scripts/build.f | tr '\n' ' ')"
if [ "$LINT" = 1 ]; then
  verilator --lint-only -Wall -Wno-fatal --top-module video_processor $SRCS
fi
FW="$ROOT/build/fw"; mkdir -p "$FW"
python3 "$ROOT/../../ip/cpu/py_core/tools/pyc.py" "$ROOT/sw/video_proc.py" -o "$FW/video_proc"
OUT="$ROOT/build/sim"; mkdir -p "$OUT" "$OUT/input_images" "$OUT/output_images"
WORK="${SIM_WORK_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/video_processor_sim.XXXXXX")}"
mkdir -p "$WORK/input_images" "$WORK/output_images"
cp -p "$OUT"/input_images/*.ppm "$WORK/input_images/" 2>/dev/null || true
rm -f "$WORK"/output_images/*.ppm
copy_back() {                                   # results -> build/sim
  cp -p "$WORK"/cpu_bootup.txt "$WORK"/video_processor_tb.log "$OUT/" 2>/dev/null || true
  cp -p "$WORK"/input_images/*.ppm "$OUT/input_images/" 2>/dev/null || true
  rm -f "$OUT"/output_images/*.ppm; cp -p "$WORK"/output_images/*.ppm "$OUT/output_images/" 2>/dev/null || true
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
ARGS=""; [ "$VCD" = 1 ] && ARGS="+vcd$VCDWIN"; [ "$QUICK" = 1 ] && ARGS="$ARGS +quick"
vvp -n video_processor_tb.vvp $ARGS | tee video_processor_tb.log
grep -q "TEST PASSED" video_processor_tb.log || { echo "[video_processor] SIMULATION FAILED"; exit 1; }
echo "[video_processor] PASSED"
