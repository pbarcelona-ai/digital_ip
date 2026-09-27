#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# gatesim.sh - gate-level check of the synthesis flow.
# Synthesizes <module> with the common Yosys flow at the testbench's sizes,
# then runs the module's own self-checking testbench (Icarus Verilog) on the
# mapped Xilinx netlist instead of the RTL, using Yosys's Xilinx cell
# simulation models for LUTs, flip-flops, CARRY4, MUXF and LUT RAM, and
# Xilinx's functional UNISIM models for RAMB18E1 / RAMB36E1 / DSP48E1.
#
# Usage: tools/gatesim.sh <module> [-p NAME=VALUE ...] [-D<define> ...] [+plusargs ...]
#   -p NAME=VALUE  synthesis parameter; must match the testbench DUT
#                  (default MAX_W=48 MAX_H=40, the testbench frame size)
#   -D<define>     testbench define, e.g. -DTB_LINE_BUF=1 together with
#                  -p LINE_BUF=1 to check the line-buffer build
#   +...           passed to the simulation (e.g. +NO_PPM, +IMG=...)
#   -yosys-dsp     simulate DSP48E1 with Yosys's functional model instead of
#                  Xilinx's UNISIM model (much less memory; use for designs
#                  with ~100+ DSPs, e.g. Lanczos, on machines with <8 GB)
#   -vcd           dump a gate-level VCD (large) and open it in Surfer when
#                  surfer and a display are available (-noview: never)
# Results: <module>/yosys/gatesim/ (netlist, build/sim logs, VCD)
# Exit status: 0 when the testbench passes on the netlist.
# -----------------------------------------------------------------------------
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="$1"; shift
DIR="$ROOT/$IP"; OUT="$DIR/yosys/gatesim"; mkdir -p "$OUT"
PARAMS=""; ARGS=(); DEFS=(); WAVES=0; YDSP=0; VIEW=auto; [ "${NO_VIEW:-0}" = 1 ] && VIEW=0
grep -q "parameter int MAX_W" "$DIR/src/$IP.sv" && PARAMS="MAX_W=48"
grep -q "parameter int MAX_H" "$DIR/src/$IP.sv" && PARAMS="$PARAMS MAX_H=40"
# DUT configuration that each testbench instantiates, where it differs from
# the RTL defaults (the netlist must be synthesized in that configuration)
case "$IP" in
  scaler_polyphase)   PARAMS="$PARAMS TAPS=8" ;;
  scaler_mip)         PARAMS="$PARAMS LEVELS=3 ANISO_MAX_LOG2=2" ;;
  scaler_anisotropic) PARAMS="$PARAMS LEVELS=4" ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -p) shift; PARAMS="$PARAMS $1" ;;
    -D*) DEFS+=("$1") ;;
    -vcd) WAVES=1 ;;
    -yosys-dsp) YDSP=1 ;;
    -noview) VIEW=0 ;;
    *)  ARGS+=("$1") ;;
  esac
  shift
done
YCELLS="$(yosys-config --datdir 2>/dev/null || echo /usr/share/yosys)/xilinx/cells_sim.v"
[ -r "$YCELLS" ] || YCELLS=/usr/share/yosys/xilinx/cells_sim.v

# Cell models. Yosys's cells_sim.v models LUTs, flip-flops, CARRY4, MUXF*,
# LUT RAM and DSP48E1 functionally, but its RAMB18E1 / RAMB36E1 are port-only
# stubs without behaviour. The block RAMs - and, as a vendor reference, the
# DSP48E1 - are therefore taken from Xilinx's functional UNISIM models
# (Apache-2.0, github.com/Xilinx/XilinxUnisimLibrary), downloaded once into
# tools/yosys/unisim/ (or set UNISIM_DIR). The netlist is simulated exactly
# as mapped, block RAMs included.
UNISIM_DIR="${UNISIM_DIR:-$ROOT/tools/yosys/unisim}"
URL=https://raw.githubusercontent.com/Xilinx/XilinxUnisimLibrary/master/verilog/src
mkdir -p "$UNISIM_DIR"
for m in unisims/RAMB18E1 unisims/RAMB36E1 unisims/DSP48E1 glbl; do
  f="$UNISIM_DIR/$(basename $m).v"
  [ -s "$f" ] || curl -sSfL -o "$f" "$URL/$m.v" \
    || { echo "gatesim.sh: cannot download $m.v; place it in $UNISIM_DIR" >&2; exit 1; }
done
CELLS="$OUT/cells_sim_functional.v"
if [ "$YDSP" = 1 ]; then STRIP='RAMB18E1|RAMB36E1'; else STRIP='RAMB18E1|RAMB36E1|DSP48E1'; fi
awk -v re="^module ($STRIP) " '$0 ~ re {skip=1} !skip{print} /^endmodule/{skip=0}' "$YCELLS" > "$CELLS"

# 1. synthesis with the common script (same as synth.sh, own output dir)
SRCS=(); while read -r f; do f="$(echo "${f%%#*}" | xargs)"; [ -n "$f" ] && SRCS+=("$DIR/src/$f"); done < "$DIR/src/build.f"
sv2v -DSYNTHESIS -w "$OUT/$IP.sv2v.v" "${SRCS[@]}"
echo "gatesim.sh: synthesizing $IP ($PARAMS)"
SYN_TOP="$IP" SYN_SRC="$OUT/$IP.sv2v.v" SYN_OUT="$OUT" SYN_PARAMS="$PARAMS" \
  yosys -q -l "$OUT/synth.log" -c "$ROOT/tools/yosys/synth_xilinx.tcl" > /dev/null 2>&1 \
  || { echo "gatesim.sh: synthesis failed (see $OUT/synth.log)" >&2; exit 1; }

# 2. testbench with the DUT parameter override removed (the netlist top has
#    its parameters already applied)
sed -E ':a;N;$!ba;s/\n  '"$IP"' #\([^;]*\) dut \(/\n  '"$IP"' dut (/' \
  "$DIR/tb/tb_$IP.sv" > "$OUT/tb_$IP.gl.sv"
grep -q "  $IP dut (" "$OUT/tb_$IP.gl.sv" || { echo "gatesim.sh: could not patch DUT instance" >&2; exit 1; }

# 3. file list: verification sources from tb/build.f, RTL replaced by netlist
FILES=()
while read -r f; do
  f="$(echo "${f%%#*}" | xargs)"; [ -n "$f" ] || continue
  case "$f" in *axi_checkers/*) FILES+=("$DIR/tb/$f") ;; esac
done < "$DIR/tb/build.f"
FILES+=("$OUT/${IP}_netlist.v" "$CELLS" "$UNISIM_DIR/RAMB18E1.v" "$UNISIM_DIR/RAMB36E1.v"
        "$UNISIM_DIR/glbl.v" "$OUT/tb_$IP.gl.sv")
[ "$YDSP" = 1 ] || FILES+=("$UNISIM_DIR/DSP48E1.v")

echo "gatesim.sh: simulating the netlist (Icarus)"
iverilog -g2012 -Wno-timescale -DTB_MAX_W=48 -DTB_MAX_H=40 ${DEFS[@]+"${DEFS[@]}"} -I "$ROOT/scaler_tb_lib/src" \
  -s "tb_$IP" -s glbl -o "$OUT/sim.vvp" "${FILES[@]}" > "$OUT/build.log" 2>&1 \
  || { grep -iE "error" "$OUT/build.log" | head; exit 1; }
NOVCD=(+NO_VCD); [ "$WAVES" = 1 ] && NOVCD=()
vvp -n "$OUT/sim.vvp" +OUTDIR="$OUT" +VCD="$OUT/tb_$IP.gl.vcd" ${NOVCD[@]+"${NOVCD[@]}"} ${ARGS[@]+"${ARGS[@]}"} > "$OUT/sim.log" 2>&1 || true
if [ "$WAVES" = 1 ] && [ -s "$OUT/tb_$IP.gl.vcd" ]; then
  echo "gatesim.sh: waveform: $OUT/tb_$IP.gl.vcd"
  SURF="${SURFER:-$(command -v surfer || true)}"
  if [ "$VIEW" != 0 ] && [ -n "$SURF" ] && [ -x "$SURF" ] && \
     { [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || [ "$(uname -s)" = Darwin ]; }; then
    echo "gatesim.sh: opening in surfer"
    nohup "$SURF" "$OUT/tb_$IP.gl.vcd" > "$OUT/surfer.log" 2>&1 &
  fi
fi
grep -E "^TEST|TB_RESULT" "$OUT/sim.log"
grep -q "TB_RESULT: PASS" "$OUT/sim.log"
