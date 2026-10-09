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
# Usage: scripts/run_sim.sh [--vcd] [--lint] [--quick]
#   --quick  sets the GPIO0[31] strap: the firmware skips the CPU and video
#            register dumps (faster). The UART 0 report is saved to build/sim/cpu_bootup.txt.
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
VCD=0; LINT=0; QUICK=0
for a in "$@"; do
  case "$a" in --vcd) VCD=1;; --lint) LINT=1;; --quick) QUICK=1;; *) echo "unknown option $a"; exit 2;; esac
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
}
trap copy_back EXIT
echo "[video_processor] simulating in $WORK (live report: $WORK/cpu_bootup.txt); results -> $OUT"
cd "$WORK"
iverilog -g2012 -Wall -Wno-timescale -s video_processor_tb -o video_processor_tb.vvp -I "$FW" -I "$ROOT/tb/tests" -I "$ROOT/../../ip/peripherals/i2c_master/tb/tests" -I "$ROOT/../../ip/peripherals/spi_flash_ctrl/tb/tests" \
  -DFW_HEX="\"$FW/video_proc.flash.hex\"" $SRCS $TB_SRCS
ARGS=""; [ "$VCD" = 1 ] && ARGS="+vcd"; [ "$QUICK" = 1 ] && ARGS="$ARGS +quick"
vvp -n video_processor_tb.vvp $ARGS | tee video_processor_tb.log
grep -q "TEST PASSED" video_processor_tb.log || { echo "[video_processor] SIMULATION FAILED"; exit 1; }
echo "[video_processor] PASSED"
