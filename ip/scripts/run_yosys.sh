#!/usr/bin/env bash
# ***************
# Filename: run_yosys.sh
# Author: FPGA Cores 4 U
# Description: Run the common Yosys Xilinx 7-series flow on one IP.
#   Sources come from <ip>/scripts/build.f, the flow is in
#   scripts/synth.ys and all results go to build/yosys/<ip>. An IP with a
#   scripts/sv2v marker file is converted with sv2v before Yosys reads it.
#   An IP's scripts/yosys_params (lines NAME=VALUE, ${IPDIR} expanded; #
#   comments) sets top-level parameters before elaboration (the sv2v
#   wrapper's defaults, or chparam), e.g. the path of ROM contents.
# Date: 2026-10-21
#
# Usage: scripts/run_yosys.sh <ip>
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || { echo "usage: $0 <ip> [synthesis options]"; exit 2; }
IP="$1"; shift; lookup "$IP"
if [[ "$CAT" == scalers ]]; then
  exec "$REPO/scalers/$IP/scripts/synth.sh" "$@"
fi
[ $# -eq 0 ] || { echo "usage: $0 <ip>"; exit 2; }
command -v yosys >/dev/null || { echo "yosys not found"; exit 1; }
BUILD_ROOT="${BUILD_ROOT:-$REPO/build}"
OUT="$BUILD_ROOT/yosys/$IP"; rm -rf "$OUT"; mkdir -p "$OUT"
# A top with SystemVerilog interface ports cannot be a Yosys top: wrap it in
# a discrete-port <top>_syn (syn_wrap.py) and read everything through sv2v
SRCS="$(filelist "$IP" | tr '\n' ' ')"
PARAMS=()                                        # NAME=VALUE from scripts/yosys_params
if [ -f "$IPDIR/scripts/yosys_params" ]; then
  while IFS= read -r ln; do
    ln="${ln%%#*}"; [ -n "${ln// }" ] || continue
    PARAMS+=("$(eval "printf '%s' \"$ln\"")")
  done < "$IPDIR/scripts/yosys_params"
fi
IFSRCS="$(grep -l '^[[:space:]]*interface[[:space:]]' $SRCS 2>/dev/null | tr '\n' ' ' || true)"
TOPSRC="$(grep -l "^[[:space:]]*module[[:space:]][[:space:]]*$TOP\b" $SRCS | head -1)"
if [ -n "$IFSRCS" ] && [ -n "$TOPSRC" ] && python3 "$REPO/scripts/syn_wrap.py" "$TOPSRC" "$TOP" $IFSRCS > "$OUT/${TOP}_syn.sv"; then
  command -v sv2v >/dev/null || { echo "sv2v not found"; exit 1; }
  for kv in "${PARAMS[@]+"${PARAMS[@]}"}"; do       # the wrapper's parameter defaults (sv2v elaborates them)
    python3 - "$OUT/${TOP}_syn.sv" "${kv%%=*}" "${kv#*=}" <<'PY'
import re, sys
p, name, val = sys.argv[1:]
s = open(p).read()
s = re.sub(r"(parameter\b[^=;,)]*\b%s\s*=\s*)[^,)\n]*" % re.escape(name), lambda m: m.group(1) + val, s, count=1)
open(p, "w").write(s)
PY
  done
  PARAMS=()
  sv2v -DSYNTHESIS $SRCS "$OUT/${TOP}_syn.sv" > "$OUT/$IP.sv2v.v"
  TOP="${TOP}_syn"
  { echo "# generated from $CAT/$IP/scripts/build.f via sv2v, top wrapped by syn_wrap.py"
    echo "read_verilog -sv $OUT/$IP.sv2v.v"
    echo "hierarchy -check -top $TOP"; } > "$OUT/read_design.ys"
elif [ -f "$IPDIR/scripts/sv2v" ]; then
  # IP includes sources the Yosys SystemVerilog reader cannot parse (e.g. the
  # scaler family): convert the whole file list with sv2v first, as the
  # scaler flow does
  command -v sv2v >/dev/null || { echo "sv2v not found"; exit 1; }
  sv2v -DSYNTHESIS $(filelist "$IP") > "$OUT/$IP.sv2v.v"     # SYNTHESIS: black boxes (e.g. dpll_dco)
  { echo "# generated from $CAT/$IP/scripts/build.f via sv2v"
    echo "read_verilog -sv $OUT/$IP.sv2v.v"
    echo "hierarchy -check -top $TOP"; } > "$OUT/read_design.ys"
else
{
  echo "# generated from $CAT/$IP/scripts/build.f"
  for f in $(filelist "$IP"); do echo "read_verilog -sv $f"; done
  echo "hierarchy -check -top $TOP"
} > "$OUT/read_design.ys"
fi
if [ "${#PARAMS[@]}" -gt 0 ]; then
  # chparam lines go before the hierarchy command of read_design.ys
  for kv in "${PARAMS[@]}"; do echo "chparam -set ${kv%%=*} ${kv#*=} $TOP"; done > "$OUT/params.ys"
  while IFS= read -r ln; do
    [[ "$ln" == hierarchy\ * ]] && cat "$OUT/params.ys"
    printf '%s\n' "$ln"
  done < "$OUT/read_design.ys" > "$OUT/read_design.tmp"
  mv "$OUT/read_design.tmp" "$OUT/read_design.ys"
fi
cd "$OUT"
yosys -l yosys.log -s "$REPO/scripts/synth.ys" > /dev/null || { tail -5 yosys.log; exit 1; }
# ltp sees module instances as combinational boxes, so the top entry is a
# false path; report leaf modules only.
grep -E "^Longest topological path in" logic_depth.rpt | grep -v " in $TOP " \
  | sed -E 's/\$paramod[^\\]*\\//' > logic_depth_summary.rpt || true
echo "[$IP] yosys done -> $OUT"
echo "  logic depth (coarse cells, per leaf module):"; sed 's/^/    /' logic_depth_summary.rpt
echo "  primitives (flat):"
PRIMITIVES="$(awk '
  $1 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $2 ~ /^[0-9]+$/ { print "  " $1 " " $2; next }
  $2 ~ /^(LUT[0-9]|FD[A-Z]+|CARRY4|RAMB|DSP|RAM[0-9]+|MUXF)/ && $1 ~ /^[0-9]+$/ { print "  " $2 " " $1 }
' utilization_flat.rpt | tail -n 12)"
if [ -n "$PRIMITIVES" ]; then printf '%s\n' "$PRIMITIVES" | sed 's/^/    /'
else echo "    (no primitive cells reported)"; fi
