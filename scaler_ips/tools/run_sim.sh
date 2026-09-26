#!/usr/bin/env bash
# Usage: tools/run_sim.sh <dir_name> [plusargs...]        (Verilator >= 5.0)
#   e.g. tools/run_sim.sh scaler_bicubic +IMG=photo.ppm +OUT_W=1280 +OUT_H=720
# Same options as <dir>/run.sh; the VCD defaults to build/<dir>/tb_<dir>.vcd.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="$1"; shift
source "$ROOT/tools/tb_args.sh"
TOP="tb_${IP}"
FL="$ROOT/$IP/tb/build.f"
BUILD="$ROOT/build/$IP/${TB_MAX_W}x${TB_MAX_H}"
mkdir -p "$BUILD"
verilator --binary --timing --trace --assert +define+SVA_ON -j 0 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-BLKSEQ \
  +define+TB_MAX_W="$TB_MAX_W" +define+TB_MAX_H="$TB_MAX_H" \
  --top-module "$TOP" -Mdir "$BUILD" -o "V$TOP" \
  -I"$ROOT/scaler_tb_lib/src" -F "$FL" > "$BUILD/build.log" 2>&1 || { cat "$BUILD/build.log"; exit 1; }
case " ${PLUSARGS[*]:-} " in *" +VCD="*|*" +NO_VCD "*) ;; *) PLUSARGS+=("+VCD=$ROOT/build/$IP/tb_${IP}.vcd") ;; esac
"$BUILD/V$TOP" "${PLUSARGS[@]}" | tee "$ROOT/build/$IP/sim.log"
grep -q "TB_RESULT: PASS" "$ROOT/build/$IP/sim.log"
