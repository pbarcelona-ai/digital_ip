#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run.sh - compile and run the sharpen_cas testbench with Icarus Verilog (>= 12).
# Needs only bash, iverilog and vvp (no Python). Can be called from any
# directory.
#
# Usage: ./run.sh [options]
#   +IMG=<file.ppm>        scale a PPM (P6) image instead of generated patterns
#                          (the build is sized from the PPM header automatically)
#   +OUT_W=<n> +OUT_H=<n>  output size for +IMG runs
#   +OUTDIR=<dir>          directory for PPM images and the VCD (default ./sim_out)
#   +NO_PPM                do not write PPM images
#   +VCD=<file>            waveform file (default <OUTDIR>/tb_sharpen_cas.vcd)
#   +NO_VCD                do not dump waveforms
#   +TIMEOUT_MS=<n>        simulation watchdog (simulated milliseconds)
#   Any other +plusarg is passed through to the simulation.
#
# Outputs (in sim_out/ unless +OUTDIR is given):
#   sim.vvp, build.log, sim.log, tb_sharpen_cas.vcd, *_in_*.ppm, *_out_*.ppm
# Exit status: 0 when the testbench prints "TB_RESULT: PASS", 1 otherwise.
# View waveforms with e.g.:  gtkwave sim_out/tb_sharpen_cas.vcd
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP="sharpen_cas"
ROOT="$(dirname "$HERE")"
TB_DIR="$HERE/tb"
SIM_DIR="$HERE/sim_out"
MAX_W=48
MAX_H=40

abspath() { case "$1" in /*) printf '%s\n' "$1" ;; *) printf '%s\n' "$PWD/$1" ;; esac; }

OUTDIR=""
VCD=""
ARGS=()
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
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *)         ARGS+=("$a") ;;
  esac
done

[ -n "$OUTDIR" ] || OUTDIR="$SIM_DIR"
[ -n "$VCD" ]    || VCD="$OUTDIR/tb_${IP}.vcd"
mkdir -p "$SIM_DIR" "$OUTDIR" "$(dirname "$VCD")"
ARGS+=("+OUTDIR=$OUTDIR" "+VCD=$VCD")

echo "run.sh: compiling tb_${IP} (TB_MAX ${MAX_W}x${MAX_H})"
cd "$TB_DIR"
if ! iverilog -g2012 -Wall -Wno-timescale -Wno-implicit-dimensions -Wno-portbind \
       -Wno-sensitivity-entire-array -Wno-sensitivity-entire-vector \
       -DTB_MAX_W="$MAX_W" -DTB_MAX_H="$MAX_H" \
       -I "$ROOT/scaler_tb_lib/src" -s "tb_${IP}" -o "$SIM_DIR/sim.vvp" -f build.f \
       > "$SIM_DIR/build.log" 2>&1; then
  cat "$SIM_DIR/build.log"
  echo "run.sh: compile FAILED" >&2
  exit 1
fi

echo "run.sh: simulating"
vvp -n "$SIM_DIR/sim.vvp" "${ARGS[@]}" | tee "$SIM_DIR/sim.log"
if grep -q "TB_RESULT: PASS" "$SIM_DIR/sim.log"; then
  echo "run.sh: PASS   (log: $SIM_DIR/sim.log, outputs: $OUTDIR)"
  exit 0
else
  echo "run.sh: FAIL   (log: $SIM_DIR/sim.log)" >&2
  exit 1
fi
