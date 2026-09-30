#!/usr/bin/env bash
# ***************
# Filename: run_sim.sh
# Author: Paul Barcelona
# Description: Compile and run the self-checking testbench of one IP
#   with Icarus Verilog. Optional VCD dump and Surfer waveform viewer.
# Date: 2026-09-29
#
# Usage: scripts/run_sim.sh <ip> [--vcd] [--wave] [--lint]
#   --vcd   write build/sim/<ip>/<tb>.vcd
#   --wave  implies --vcd, then opens the VCD in Surfer if installed
#   --lint  run verilator --lint-only on the RTL first
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || { echo "usage: $0 <ip> [--vcd] [--wave] [--lint]"; exit 2; }
IP="$1"; shift; lookup "$IP"
if [[ "$CAT" == scalers ]]; then
  SCALER_ARGS=()
  for a in "$@"; do
    case "$a" in
      --vcd) ;;
      --wave) SCALER_ARGS+=("-view") ;;
      --lint) echo "--lint is not available for scaler IPs; use make sim IP=$IP for the Verilator/SVA flow" >&2; exit 2 ;;
      *) SCALER_ARGS+=("$a") ;;
    esac
  done
  exec "$REPO/tools/run_iverilog.sh" "$IP" "${SCALER_ARGS[@]}"
fi
VCD=0; WAVE=0; LINT=0
for a in "$@"; do
  case "$a" in --vcd) VCD=1;; --wave) VCD=1; WAVE=1;; --lint) LINT=1;;
                *) echo "unknown option $a"; exit 2;; esac
done
BUILD_ROOT="${BUILD_ROOT:-$REPO/build}"
OUT="$BUILD_ROOT/sim/$IP"; mkdir -p "$OUT"
SRCS="$(filelist "$IP" | tr '\n' ' ')"
# Testbench helper models may need the shared register file: add it if absent
case "$SRCS" in *ip_axil_regs.sv*) ;; *) EXTRA="$REPO/shared/src/common/ip_axil_regs.sv" ;; esac
TB_SRCS="$(filelist "$IP" tb/scripts/build.f | tr '\n' ' ')"

if [ "$LINT" = 1 ]; then
  verilator --lint-only -Wall -Wno-fatal --top-module "$TOP" $SRCS
fi
cd "$OUT"                                   # VCD files land here
iverilog -g2012 -Wall -Wno-timescale -s "$TB" -o "$TB.vvp" $SRCS ${EXTRA:-} $TB_SRCS
ARGS=""; [ "$VCD" = 1 ] && ARGS="+vcd"
vvp -n "$TB.vvp" $ARGS | tee "$TB.log"
grep -q "TEST PASSED" "$TB.log" || { echo "[$IP] SIMULATION FAILED"; exit 1; }
echo "[$IP] PASSED"
if [ "$WAVE" = 1 ]; then
  VF="$(ls -1 "$OUT"/*.vcd 2>/dev/null | head -1 || true)"
  if command -v surfer >/dev/null 2>&1 && [ -n "$VF" ]; then surfer "$VF" &
  else echo "surfer not found; install from https://surfer-project.org and open $OUT/*.vcd"; fi
fi
