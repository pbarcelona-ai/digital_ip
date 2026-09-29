#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# synth.sh - Yosys synthesis of scaler_nearest for Xilinx FPGAs.
# Needs bash, sv2v (SystemVerilog -> Verilog-2005) and yosys (>= 0.33).
# Can be called from any directory. All results go to scaler_nearest/yosys/.
#
# Flow: scripts/build.f -> sv2v -> yosys -c tools/yosys/synth_xilinx.tcl
#       (read, elaborate, compile, DSP packing, optimize, memory -> BRAM /
#       LUT RAM, map to LUT/carry/FF) -> hierarchical utilization report
#
# Usage: ./scripts/synth.sh [options]
#   -p NAME=VALUE    override a top-level parameter (repeatable), e.g.
#                    -p MAX_W=1920 -p MAX_H=1080 -p LINE_BUF=1
#                    defaults for this module: MAX_W=640 MAX_H=480
#   -family FAMILY   synth_xilinx family: xc7 (default), xcu, xcup, ...
#   -flags "..."     extra synth_xilinx options, e.g. "-nodsp" or "-abc9"
#   -iopad           insert I/O and clock buffers (default: out-of-context)
#   -json            also write the netlist as JSON (large)
#   -h, --help       this text
#   Environment: SYN_DSP_PACK=1 enables Yosys DSP48 register/adder packing,
#   SYN_SRL=1 enables SRL inference. Both are off by default because Yosys
#   0.33 produced incorrect netlists with them (see README, Synthesis).
#
# Outputs in yosys/:
#   utilization_hier.rpt   hierarchical utilization (totals per instance)
#   utilization.rpt        raw Yosys "stat -tech xilinx" per module
#   timing.rpt             critical path estimate (Yosys sta, cell delays only)
#   synth.log              complete Yosys log
#   scaler_nearest.sv2v.v         converted Verilog-2005 source that Yosys read
#   scaler_nearest_netlist.v      mapped netlist (Verilog), scaler_nearest.edf (EDIF)
# Exit status: 0 on success.
# -----------------------------------------------------------------------------
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOP="scaler_nearest"
IP_DIR="$(dirname "$HERE")"
ROOT="$(dirname "$IP_DIR")"
OUT="$IP_DIR/yosys"
TCL="$ROOT/tools/yosys/synth_xilinx.tcl"
AWK="$ROOT/tools/yosys/util_hier.awk"

declare -A PARAM=()
PORDER=()
DEFPARAMS="MAX_W=640 MAX_H=480"
for kv in $DEFPARAMS; do
  PARAM[${kv%%=*}]="${kv#*=}"; PORDER+=("${kv%%=*}")
done
FAMILY=xc7; FLAGS=""; IOPAD=0; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    -p)       shift; k="${1%%=*}"; [ -n "${PARAM[$k]+x}" ] || PORDER+=("$k"); PARAM[$k]="${1#*=}" ;;
    -family)  shift; FAMILY="$1" ;;
    -flags)   shift; FLAGS="$1" ;;
    -iopad)   IOPAD=1 ;;
    -json)    JSON=1 ;;
    -h|--help) sed -n '3,/^# ---/p' "$0" | sed '$d'; exit 0 ;;
    *) echo "synth.sh: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done
PARAMS=""
for k in ${PORDER[@]+"${PORDER[@]}"}; do PARAMS="$PARAMS $k=${PARAM[$k]}"; done

command -v sv2v  >/dev/null || { echo "synth.sh: sv2v not found (https://github.com/zachjs/sv2v)" >&2; exit 1; }
command -v yosys >/dev/null || { echo "synth.sh: yosys not found" >&2; exit 1; }
mkdir -p "$OUT"

# ---- source list (relative to src/)
SRCS=()
while read -r f; do
  f="${f%%#*}"; f="$(echo "$f" | xargs)"; [ -n "$f" ] || continue
  SRCS+=("$IP_DIR/src/$f")
done < "$IP_DIR/scripts/build.f"

echo "synth.sh: $TOP  family=$FAMILY  params:${PARAMS:- (defaults)}"
echo "synth.sh: sv2v ${#SRCS[@]} file(s)"
sv2v -DSYNTHESIS -w "$OUT/$TOP.sv2v.v" "${SRCS[@]}"

echo "synth.sh: yosys (log: $OUT/synth.log)"
S=$(date +%s)
if ! SYN_TOP="$TOP" SYN_SRC="$OUT/$TOP.sv2v.v" SYN_OUT="$OUT" SYN_PARAMS="$PARAMS" \
     SYN_FAMILY="$FAMILY" SYN_FLAGS="$FLAGS" SYN_IOPAD="$IOPAD" SYN_JSON="$JSON" \
     yosys -q -l "$OUT/synth.log" -c "$TCL" > "$OUT/yosys_stdout.txt" 2>&1; then
  grep -E "ERROR" "$OUT/synth.log" | head -5 >&2
  echo "synth.sh: FAILED" >&2
  exit 1
fi

{
  echo "Module     : $TOP"
  echo "Family     : $FAMILY"
  echo "Parameters :${PARAMS:- (defaults)}"
  echo "Tools      : $(yosys -V | cut -d' ' -f1-2), $(sv2v --version)"
  echo "Run time   : $(( $(date +%s) - S )) s"
  echo
  awk -f "$AWK" -v top="$TOP" "$OUT/utilization.rpt"
  echo
  cp_ps=$(awk '/^Latest arrival time/ {v=$NF; sub(/:$/, "", v); print v; exit}' "$OUT/timing.rpt" 2>/dev/null)
  if [ -n "$cp_ps" ]; then
    echo "Critical path (cell delays only, no routing): $cp_ps ps  (see timing.rpt)"
  fi
} > "$OUT/utilization_hier.rpt"
cat "$OUT/utilization_hier.rpt"
echo
echo "synth.sh: warnings: $(grep -c '^Warning' "$OUT/synth.log" || true)   results: $OUT"
