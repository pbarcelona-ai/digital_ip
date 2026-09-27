#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run.sh - compile and run the scaler_bicubic testbench with Icarus Verilog (>= 12).
# Needs only bash, iverilog and vvp (no Python). Can be called from any
# directory.
#
# Usage: ./run.sh [options]
#   +IMG=<file.ppm>        scale a PPM (P6) image instead of generated patterns
#                          (the build is sized from the PPM header automatically)
#   +OUT_W=<n> +OUT_H=<n>  output size for +IMG runs
#   +OUTDIR=<dir>          directory for PPM images and the VCD (default ./sim_out)
#   +NO_PPM                do not write PPM images
#   +VCD=<file>            waveform file (default <OUTDIR>/tb_scaler_bicubic.vcd)
#   +NO_VCD                do not dump waveforms
#   -view / -noview        always try / never try to open the VCD in Surfer
#                          (default: open it when surfer and a display exist;
#                          NO_VIEW=1 in the environment is the same as -noview)
#   +TIMEOUT_MS=<n>        simulation watchdog (simulated milliseconds)
#   -D<NAME>[=<value>]     compile-time define, e.g. -DTB_PINGPONG=1 (double
#                          frame buffer) or -DTB_LINE_BUF=1 (line buffer)
#   Any other +plusarg is passed through to the simulation.
#   --clean                delete sim_out/ and exit
#   -h, --help             show this help
#
# Old *.ppm / *.vcd files in sim_out/ are removed at the start of every run
# (files in a user-given +OUTDIR are never deleted).
#
# Outputs (in sim_out/ unless +OUTDIR is given):
#   sim.vvp, build.log, sim.log, tb_scaler_bicubic.vcd, *_in_*.ppm, *_out_*.ppm
# Exit status: 0 when the testbench prints "TB_RESULT: PASS", 1 otherwise.
# View waveforms with e.g.:  gtkwave sim_out/tb_scaler_bicubic.vcd
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP="scaler_bicubic"
ROOT="$(dirname "$HERE")"
TB_DIR="$HERE/tb"
SIM_DIR="$HERE/sim_out"
MAX_W=48
MAX_H=40

abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac; }

OUTDIR=""
VCD=""
NO_VCD=0
VIEW=auto
[ "${NO_VIEW:-0}" = 1 ] && VIEW=0
ARGS=()
DEFS=()
for a in "$@"; do
  case "$a" in
    +IMG=*)
      f="$(abspath "${a#+IMG=}")"
      [ -r "$f" ] || { echo "run.sh: cannot read $f" >&2; exit 1; }
      # PPM header: magic width height maxval ('#' comments allowed)
      read -r magic w h _ < <(LC_ALL=C head -c 512 "$f" | LC_ALL=C tr -c '[:print:]\n' ' ' \
          | sed 's/#.*//' | tr -s ' \t\r\n' '\n' | head -4 | tr '\n' ' '; echo) || true
      [ "${magic:-}" = "P6" ] || { echo "run.sh: $f is not a binary PPM (P6)" >&2; exit 1; }
      [ "$w" -gt "$MAX_W" ] && MAX_W=$w
      [ "$h" -gt "$MAX_H" ] && MAX_H=$h
      ARGS+=("+IMG=$f") ;;
    +OUTDIR=*) OUTDIR="$(abspath "${a#+OUTDIR=}")" ;;
    +VCD=*)    VCD="$(abspath "${a#+VCD=}")" ;;
    +NO_VCD)   NO_VCD=1; ARGS+=("$a") ;;
    -view)     VIEW=1 ;;
    -noview)   VIEW=0 ;;
    -D*)       DEFS+=("$a") ;;
    -h|--help) sed -n '3,/^# ---/p' "$0" | sed '$d'; exit 0 ;;
    --clean)   rm -rf "$SIM_DIR"; echo "run.sh: removed $SIM_DIR"; exit 0 ;;
    *)         ARGS+=("$a") ;;
  esac
done

[ -n "$OUTDIR" ] || OUTDIR="$SIM_DIR"
[ -n "$VCD" ]    || VCD="$OUTDIR/tb_${IP}.vcd"
mkdir -p "$SIM_DIR" "$OUTDIR" "$(dirname "$VCD")"
rm -f "$SIM_DIR"/*.ppm "$SIM_DIR"/*.vcd    # stale results from earlier runs
ARGS+=("+OUTDIR=$OUTDIR" "+VCD=$VCD")

# ---- waveform viewer: open the VCD in Surfer (https://surfer-project.org)
# Launched in the background (the script still returns the test result) when
# a VCD was written, Surfer is installed (or SURFER=<path> is set) and a
# display is available. Disabled by -noview or NO_VIEW=1 (run_all.sh sets it).
open_waveform() {
  local vcd="$1"
  [ "$NO_VCD" = 1 ] && return 0
  [ -s "$vcd" ] || return 0
  echo "run.sh: waveform: $vcd"
  [ "$VIEW" = 0 ] && return 0
  local surfer="${SURFER:-$(command -v surfer || true)}"
  if [ -z "$surfer" ] || [ ! -x "$surfer" ]; then
    [ "$VIEW" = 1 ] && echo "run.sh: surfer not found (install it or set SURFER=/path/to/surfer)" >&2
    return 0
  fi
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "$(uname -s)" != Darwin ]; then
    [ "$VIEW" = 1 ] && echo "run.sh: no display available, not starting surfer" >&2
    return 0
  fi
  echo "run.sh: opening in surfer"
  nohup "$surfer" "$vcd" > "$SIM_DIR/surfer.log" 2>&1 &
}

echo "run.sh: compiling tb_${IP} (TB_MAX ${MAX_W}x${MAX_H})"
cd "$TB_DIR"
if ! iverilog -g2012 -Wall -Wno-timescale -Wno-implicit-dimensions -Wno-portbind \
       -Wno-sensitivity-entire-array -Wno-sensitivity-entire-vector \
       -DTB_MAX_W="$MAX_W" -DTB_MAX_H="$MAX_H" ${DEFS[@]+"${DEFS[@]}"} \
       -I "$ROOT/scaler_tb_lib/src" -s "tb_${IP}" -o "$SIM_DIR/sim.vvp" -f build.f \
       > "$SIM_DIR/build.log" 2>&1; then
  cat "$SIM_DIR/build.log"
  echo "run.sh: compile FAILED" >&2
  exit 1
fi

echo "run.sh: simulating"
vvp -n "$SIM_DIR/sim.vvp" "${ARGS[@]}" | tee "$SIM_DIR/sim.log"
open_waveform "$VCD"
if grep -q "TB_RESULT: PASS" "$SIM_DIR/sim.log"; then
  echo "run.sh: PASS   (log: $SIM_DIR/sim.log, outputs: $OUTDIR)"
  exit 0
else
  echo "run.sh: FAIL   (log: $SIM_DIR/sim.log)" >&2
  exit 1
fi
