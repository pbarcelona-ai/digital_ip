#!/usr/bin/env bash
# Usage: tools/run_sim.sh <dir_name> [plusargs...]        (Verilator >= 5.0)
#   e.g. tools/run_sim.sh scaler_bicubic +IMG=photo.ppm +OUT_W=1280 +OUT_H=720
# Same options as <dir>/run.sh (incl. -view / -noview for Surfer); the VCD
# defaults to build/scaler/<dir>/tb_<dir>.vcd.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IP="$1"; shift
source "$ROOT/tools/tb_args.sh"
TOP="tb_${IP}"
FL="$ROOT/scalers/$IP/tb/build.f"
BUILD="$ROOT/build/scaler/$IP/${TB_MAX_W}x${TB_MAX_H}$(printf "%s" "${VDEFS[*]:-}" | tr -c "A-Za-z0-9" "_")"
mkdir -p "$BUILD"
verilator --binary --timing --trace --assert +define+SVA_ON -j 0 -Wno-fatal -Wno-WIDTH -Wno-UNUSEDSIGNAL \
  -Wno-UNUSEDPARAM -Wno-DECLFILENAME -Wno-INITIALDLY -Wno-BLKSEQ \
  +define+TB_MAX_W="$TB_MAX_W" +define+TB_MAX_H="$TB_MAX_H" ${VDEFS[@]+"${VDEFS[@]}"} \
  --top-module "$TOP" -Mdir "$BUILD" -o "V$TOP" \
  -I"$ROOT/scalers/scaler_tb_lib/src" -I"$ROOT/scalers/$IP/tb/tests" -F "$FL" > "$BUILD/build.log" 2>&1 || { cat "$BUILD/build.log"; exit 1; }
case " ${PLUSARGS[*]:-} " in *" +VCD="*|*" +NO_VCD "*) ;; *) PLUSARGS+=("+VCD=$ROOT/build/scaler/$IP/tb_${IP}.vcd") ;; esac
"$BUILD/V$TOP" "${PLUSARGS[@]}" | tee "$ROOT/build/scaler/$IP/sim.log"

# open the waveform in Surfer (same rules as <dir>/run.sh: -view / -noview,
# NO_VIEW=1, SURFER=<path>; needs a display; started in the background)
VCDF=""
for a in "${PLUSARGS[@]}"; do case "$a" in +VCD=*) VCDF="${a#+VCD=}" ;; +NO_VCD) VCDF="" ; break ;; esac; done
if [ -n "$VCDF" ] && [ -s "$VCDF" ]; then
  echo "run_sim.sh: waveform: $VCDF"
  SURF="${SURFER:-$(command -v surfer || true)}"
  if [ "$VIEW" != 0 ]; then
    if [ -z "$SURF" ] || [ ! -x "$SURF" ]; then
      [ "$VIEW" = 1 ] && echo "run_sim.sh: surfer not found (install it or set SURFER=/path/to/surfer)" >&2
    elif [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && [ "$(uname -s)" != Darwin ]; then
      [ "$VIEW" = 1 ] && echo "run_sim.sh: no display available, not starting surfer" >&2
    else
      echo "run_sim.sh: opening in surfer"
      nohup "$SURF" "$VCDF" > "$ROOT/build/scaler/$IP/surfer.log" 2>&1 &
    fi
  fi
fi
grep -q "TB_RESULT: PASS" "$ROOT/build/scaler/$IP/sim.log"
