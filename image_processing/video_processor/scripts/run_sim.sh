#!/usr/bin/env bash
# ***************
# Filename: run_sim.sh
# Author: FPGA Cores 4 U
# Description: Compile the firmware (sw/video_proc.py, which imports the CPU
#   initialisation sw/video_init.py -> build/fw/video_proc.*, pyc.py)
#   and run the video_processor system testbench with Icarus Verilog.
#   Sources: scripts/build.f then tb/scripts/build.f. Output goes to
#   build/sim. Fails unless the log contains TEST PASSED.
# Date: 2026-10-14
# ***************
# Usage: scripts/run_sim.sh [--vcd] [--wave] [--vcd-start=<us>] [--vcd-stop=<us>] [--lint] [--quick] [--ideal-pll]
#                           [--list-tests] [--gif=<file>] [--gif-bw] [--gif-frames=<n>]
#                           [--detect=<classes>] [--box=<style> | --box=<class>:<style>,...]
#                           [--targets=<n>] [--direct-log] [--video-fps=<f>] [--video-start=<s>]
#                           [--select=<1|2|3|pedestrians|faces|vehicles>]
#   --list-tests  print the name and description of each test the system
#            testbench runs (ip/scripts/list_tests.py), then exit; every run
#            also prints the test names at its start. The tests, in order:
#            test_boot, test_core_reset, test_firmware, test_vision_output,
#            test_hdmi, test_lvds, test_adapter, test_images, test_tracking,
#            test_uart_report
#   --gif=<file>  tracking test input: any animated GIF (also GIF_IN=<file>);
#            its size sets the tracking frame size (fitted to 320 x 240).
#            Several GIFs, comma separated (--gif=a.gif,b.gif,c.gif), are
#            sent one after the other in one run (boot and image test once):
#            the firmware sets every block up again for each GIF; each gets
#            its own tracked GIF and sim_transcript_<name>.txt
#            A camera video (MP4, MOV, MKV, WebM: H.264, HEVC, ...) is taken
#            the same way (--gif=tb/images/clip.mp4): tb/scripts/mp4_io.py
#            (PyAV, python3 -m pip install av) samples it at --video-fps
#            from --video-start, fits the frames to 320 x 240 and writes the
#            GIF the testbench sends (only the frames --gif-first /
#            --gif-frames ask for); the tracked output is also written as
#            build/sim/video-output/<name>[_from<n>]_tracked.mp4 (H.264, 2x)
#   --video-fps=<f>  frames per second taken from a video (default 10)
#   --video-start=<s>  start time in a video, seconds (default 0)
#   --gif-bw  convert a colour input GIF to black and white (BT.601 luma; the
#            converted GIF is saved as gif-input/<name>_bw.gif); without
#            it a colour GIF goes through the pipeline in colour
#   --gif-frames=<n>  send only the first n frames of the tracking GIF
#            (shorter run; default all of them)
#   --gif-first=<n>  start at frame n of the GIF (0 = the first; with
#            --gif-frames, a long GIF in parts run side by side); the
#            results are named <name>_from<n>
#   --select=<what>  what to detect, the short form of --detect: 1 or
#            pedestrians, 2 or faces, 3 or vehicles (cars, buses, trucks,
#            planes: the automobile and vehicle detectors); comma separated
#            for more than one (e.g. --select=2, --select=1,3)
#   --detect=<classes>  object classes to detect and track, comma separated:
#            pedestrian, face, automobile (car), vehicle (bus, truck), or all
#            (default pedestrian). Each class has its own detector and box
#            colour: pedestrian green, face magenta, automobile cyan, vehicle
#            orange (e.g. --detect=all, --detect=face,car)
#            Detection uses colour, edges and motion (feature_detect: Sobel
#            edges, motion against a per-cell background, camera shift)
#   --box=<style>  box drawn round every tracked object: dashed-box, solid-box,
#            dashed-circle, solid-circle, dashed-oval, solid-oval (an ellipse
#            inside the box), solid-centre (a solid box in the middle of the
#            target, a quarter of its size); default dashed-box for
#            pedestrians and faces, solid-centre for automobiles and vehicles;
#            --box=<class>:<style>,... per class (e.g. --box=solid-circle,
#            --box=face:dashed-circle,car:solid-box)
#   --targets=<n>  most targets tracked at any time, all classes together
#            (1-12, default 12; up to 3 per class, each with its own box)
#   --direct-log  direct transcript: the firmware writes only the tracking
#            (section 8: search / track lines with the overlay boxes, and the
#            summary) through a GPIO port the testbench writes straight to
#            the transcript file, instead of the whole report over UART 0;
#            the register dumps are skipped (as --quick)
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
#            the loop and oscillator models (much faster simulation)
# UART 0 transcript: the firmware's report is written line by line, as the
#   simulation runs, to build/sim/sim_transcript_<GIF name>.txt (e.g.
#   sim_transcript_pedestrian_walk.txt, sim_transcript_bouncing-ricochets.txt),
#   so it is there even when the run is stopped part way.
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
#   it fails or is interrupted); only the UART 0 transcript (small, one line
#   at a time) is written straight to build/sim.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
filelist() { grep -Ev '^\s*(#|$)' "$ROOT/$1" | sed "s#^#$ROOT/#"; }
VCD=0; WAVE=0; LINT=0; QUICK=0; VCDWIN=""; DEFS=""; GIFARGS=""; GIF_SUFFIX=""
VFPS=10; VSTART=0; VFIRST=0; VFRAMES=0; VIDEOS=""
for a in "$@"; do
  case "$a" in
    --vcd) VCD=1;; --wave) VCD=1; WAVE=1;; --lint) LINT=1;; --quick) QUICK=1;;
    --ideal-pll) DEFS="$DEFS -DDPLL_IDEAL";;
    --list-tests) python3 "$ROOT/../../ip/scripts/list_tests.py" "$ROOT"; exit 0;;
    --gif-frames=*) GIFARGS="$GIFARGS +GIF_FRAMES=${a#--gif-frames=}"; VFRAMES="${a#--gif-frames=}";;
    --gif-first=*) GIFARGS="$GIFARGS +GIF_FIRST=${a#--gif-first=}"; GIF_SUFFIX="_from${a#--gif-first=}"; VFIRST="${a#--gif-first=}";;
    --video-fps=*) VFPS="${a#--video-fps=}";;
    --video-start=*) VSTART="${a#--video-start=}";;
    --gif=*) GIF_IN="${a#--gif=}";;
    --gif-bw) GIFARGS="$GIFARGS +GIF_BW";;
    --detect=*) GIFARGS="$GIFARGS +DETECT=${a#--detect=}";;
    --select=*) GIFARGS="$GIFARGS +DETECT=${a#--select=}";;
    --box=*) GIFARGS="$GIFARGS +BOX=${a#--box=}";;
    --targets=*) GIFARGS="$GIFARGS +TARGETS=${a#--targets=}";;
    --direct-log) GIFARGS="$GIFARGS +direct";;
    --vcd-start=*) VCDWIN="$VCDWIN +vcd_start_us=${a#--vcd-start=}";;
    --vcd-stop=*)  VCDWIN="$VCDWIN +vcd_stop_us=${a#--vcd-stop=}";;
    *) echo "unknown option $a"; exit 2;;
  esac
done
GIF_NAMES=""
if [ -n "${GIF_IN:-}" ]; then                    # the simulation runs elsewhere: absolute paths
  ABS=""
  VTMP=""
  IFS=',' read -ra GIFS <<< "$GIF_IN"
  for g in "${GIFS[@]}"; do
    [ -f "$g" ] || { echo "[video_processor] GIF not found: $g"; exit 2; }
    n="$(basename "$g")"
    case "$(echo "${n##*.}" | tr 'A-Z' 'a-z')" in
      mp4|m4v|mov|mkv|webm|avi)                 # a video: the frames asked for, as a GIF (this run's own)
        [ -n "$VTMP" ] || VTMP="$(mktemp -d "${TMPDIR:-/tmp}/video_processor_video.XXXXXX")"
        NF=0; [ "$VFRAMES" = 0 ] || NF=$((VFIRST + VFRAMES))
        python3 "$ROOT/tb/scripts/mp4_io.py" to-gif "$g" "$VTMP/${n%.*}.gif" --fps "$VFPS" --start "$VSTART" --frames "$NF" || exit 2
        ABS="$ABS${ABS:+,}$VTMP/${n%.*}.gif"; VIDEOS="$VIDEOS ${n%.*}";;
      *) ABS="$ABS${ABS:+,}$(cd "$(dirname "$g")" && pwd)/$n";;
    esac
    GIF_NAMES="$GIF_NAMES ${n%.*}"
  done
  GIF_IN="$ABS"
else
  GIF_NAMES="pedestrian_walk"
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
  cp -p "$WORK"/video_processor_tb.log "$OUT/" 2>/dev/null || true
  cp -p "$WORK"/video_processor_tb.log "$OUT/video_processor_tb_$GIF_NAME.log" 2>/dev/null || true
  cp -p "$WORK"/input_images/*.ppm "$OUT/input_images/" 2>/dev/null || true
  rm -f "$OUT"/output_images/*.ppm                # GIFs: this run's results replace the same names only
  cp -p "$WORK"/output_images/*.ppm "$OUT/output_images/" 2>/dev/null || true
  cp -p "$WORK"/gif-output/*.gif "$OUT/gif-output/" 2>/dev/null || true
  cp -p "$WORK"/gif-input/*.gif "$OUT/gif-input/" 2>/dev/null || true
  cp -p "$WORK"/*.vcd "$OUT/" 2>/dev/null || true
  for v in $VIDEOS; do                          # a video's tracked output also as MP4
    for t in "$WORK"/gif-output/"$v"_tracked.gif "$WORK"/gif-output/"$v"_from*_tracked.gif; do
      [ -f "$t" ] || continue
      mkdir -p "$OUT/video-output"
      b="$(basename "$t")"
      python3 "$ROOT/tb/scripts/mp4_io.py" to-mp4 "$t" "$OUT/video-output/${b%.gif}.mp4" || true
    done
  done
  [ -z "${VTMP:-}" ] || rm -rf "$VTMP"
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
set -- $GIF_NAMES
if [ $# -gt 1 ]; then GIF_NAME="$(echo $GIF_NAMES | tr " " "+")"; else GIF_NAME="$1$GIF_SUFFIX"; fi   # several GIFs: sim_transcript_<a>+<b>.txt + one per GIF
TRANSCRIPT="$OUT/sim_transcript_$GIF_NAME.txt"
echo "[video_processor] simulating in $WORK; transcript (live): $TRANSCRIPT; results -> $OUT"
cp -p "$FW"/video_proc.flash.hex "$WORK/"                # this run's own copy: parallel runs may rebuild build/fw
cd "$WORK"
iverilog -g2012 -Wall -Wno-timescale -s video_processor_tb -o video_processor_tb.vvp -I "$FW" -I "$ROOT/tb/tests" \
  -DFW_HEX="\"$WORK/video_proc.flash.hex\"" $DEFS $SRCS $TB_SRCS
ARGS="+GIF_IN=${GIF_IN:-$ROOT/tb/images/pedestrian_walk.gif}$GIFARGS +TRANSCRIPT=$TRANSCRIPT"
[ "$VCD" = 1 ] && ARGS="$ARGS +vcd$VCDWIN"; [ "$QUICK" = 1 ] && ARGS="$ARGS +quick"
vvp -n video_processor_tb.vvp $ARGS | tee video_processor_tb.log
grep -q "TEST PASSED" video_processor_tb.log || { echo "[video_processor] SIMULATION FAILED"; exit 1; }
echo "[video_processor] PASSED"
