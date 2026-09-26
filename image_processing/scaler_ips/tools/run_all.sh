#!/usr/bin/env bash
# Runs every testbench and prints a summary. Bash only - no Python needed.
# Usage: [SIM=iverilog|verilator] tools/run_all.sh [dir ...] [+plusarg ...]
#   SIM defaults to iverilog. Default dir list = all modules and IPs.
#   VCD dumping is disabled for regressions (+NO_VCD) unless VCD=1 is set.
#   Arguments starting with '+' are passed to every IP testbench, e.g.
#     tools/run_all.sh +IMG=photo.ppm        (all IPs scale photo.ppm)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${SIM:-iverilog}"
case "$SIM" in
  iverilog)  RUN="$ROOT/tools/run_iverilog.sh"; LOGDIR="" ;;
  verilator) RUN="$ROOT/tools/run_sim.sh";      LOGDIR="$ROOT/build" ;;
  *) echo "unknown SIM=$SIM"; exit 2 ;;
esac
DIRS=(); ARGS=()
for a in "$@"; do case "$a" in +*) ARGS+=("$a") ;; *) DIRS+=("$a") ;; esac; done
if [ ${#DIRS[@]} -eq 0 ]; then
  if [ ${#ARGS[@]} -eq 0 ]; then DIRS=(axi_checkers axil_regbus axil_split scaler_ctrl banked_framebuf scaler_dda); fi
  DIRS+=(scaler_nearest scaler_bilinear scaler_edge_directed scaler_polyphase scaler_bicubic \
  scaler_lanczos scaler_mip scaler_trilinear scaler_anisotropic sharpen_cas spatial_upscaler)
fi
fail=0
for d in "${DIRS[@]}"; do
  case "$d" in scaler_*|sharpen_*|spatial_*) A=(${ARGS[@]+"${ARGS[@]}"}) ;; *) A=() ;; esac
  [ "$d" = scaler_ctrl ] && A=()
  [ "${VCD:-0}" = 1 ] || A+=("+NO_VCD")
  if "$RUN" "$d" ${A[@]+"${A[@]}"} > /dev/null 2>&1; then r=PASS; else r=FAIL; fail=1; fi
  printf "%-10s %-22s %s  %s\n" "$SIM" "$d" "$r" "$(grep -h TB_RESULT "${LOGDIR:-$ROOT/$d/sim_out}${LOGDIR:+/$d}/sim.log" 2>/dev/null)"
done
exit $fail
