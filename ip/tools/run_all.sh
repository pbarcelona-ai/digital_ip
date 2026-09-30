#!/usr/bin/env bash
# Runs every testbench and prints a summary. Bash only - no Python needed.
# Usage: [SIM=iverilog|verilator] [MODE=frame|pingpong|linebuf] [VCD=1] \
#        tools/run_all.sh [dir ...] [+plusarg ...]
#   SIM  : simulator (default iverilog)
#   MODE : frame-store mode of the DUTs (default frame)
#            frame    - single frame buffer (all testbenches)
#            pingpong - double frame buffer: every IP with PINGPONG, plus the
#                       scaler_ctrl ping-pong sequencing test
#            linebuf  - line buffer: every IP with LINE_BUF
#          In pingpong / linebuf mode only the testbenches that support the
#          mode are run (unless directories are named explicitly).
#   VCD  : 1 keeps waveform dumps (default off for speed, +NO_VCD); Surfer
#          is never launched by the regression (NO_VIEW=1)
#   Arguments starting with '+' are passed to every IP testbench, e.g.
#     tools/run_all.sh +IMG=photo.ppm        (all IPs scale photo.ppm)
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NO_VIEW=1          # never open waveform viewers during a regression
SIM="${SIM:-iverilog}"
MODE="${MODE:-frame}"
SCALER_OUTDIR="${SCALER_OUTDIR:-}"
case "$SIM" in
  iverilog)  RUN="$ROOT/tools/run_iverilog.sh"; LOGDIR="" ;;
  verilator) RUN="$ROOT/tools/run_sim.sh";      LOGDIR="$ROOT/build/scaler" ;;
  *) echo "unknown SIM=$SIM"; exit 2 ;;
esac
MODULES=(axi_checkers axil_regbus axil_split scaler_ctrl banked_framebuf scaler_dda)
LB_IPS=(scaler_nearest scaler_bilinear scaler_edge_directed scaler_polyphase scaler_bicubic
        scaler_lanczos spatial_upscaler)
PP_IPS=("${LB_IPS[@]}" scaler_mip scaler_trilinear scaler_anisotropic)
ALL_IPS=(scaler_nearest scaler_bilinear scaler_edge_directed scaler_polyphase scaler_bicubic
         scaler_lanczos scaler_mip scaler_trilinear scaler_anisotropic sharpen_cas spatial_upscaler)
case "$MODE" in
  frame)    DEF=();                  DEFAULT_DIRS=("${MODULES[@]}" "${ALL_IPS[@]}") ;;
  pingpong) DEF=(-DTB_PINGPONG=1);   DEFAULT_DIRS=(scaler_ctrl "${PP_IPS[@]}") ;;
  linebuf)  DEF=(-DTB_LINE_BUF=1);   DEFAULT_DIRS=("${LB_IPS[@]}") ;;
  *) echo "unknown MODE=$MODE"; exit 2 ;;
esac
DIRS=(); ARGS=()
for a in "$@"; do case "$a" in +*) ARGS+=("$a") ;; *) DIRS+=("$a") ;; esac; done
if [ ${#DIRS[@]} -eq 0 ]; then
  if [ ${#ARGS[@]} -eq 0 ]; then DIRS=("${DEFAULT_DIRS[@]}")
  else for d in "${DEFAULT_DIRS[@]}"; do case "$d" in scaler_*|sharpen_*|spatial_*) [ "$d" = scaler_ctrl ] || DIRS+=("$d") ;; esac; done
  fi
fi
fail=0
for d in "${DIRS[@]}"; do
  case "$d" in scaler_*|sharpen_*|spatial_*) A=(${ARGS[@]+"${ARGS[@]}"}) ;; *) A=() ;; esac
  [ "$d" = scaler_ctrl ] && A=()
  if [ "$SIM" = iverilog ] && [ -n "$SCALER_OUTDIR" ]; then
    A+=("+OUTDIR=$SCALER_OUTDIR/$d")
  fi
  # mode define (scaler_ctrl uses its own switch for the ping-pong test)
  if [ "$d" = scaler_ctrl ]; then [ "$MODE" = pingpong ] && A+=(-DTB_NBUF=2)
  else case "$d" in scaler_*|spatial_*) A+=(${DEF[@]+"${DEF[@]}"}) ;; esac; fi
  [ "${VCD:-0}" = 1 ] || A+=("+NO_VCD")
  if "$RUN" "$d" ${A[@]+"${A[@]}"} > /dev/null 2>&1; then r=PASS; else r=FAIL; fail=1; fi
  if [ "$SIM" = verilator ]; then
    SIMLOG="$ROOT/build/scaler/$d/sim.log"
  elif [ -n "$SCALER_OUTDIR" ]; then
    SIMLOG="$SCALER_OUTDIR/$d/sim.log"
  else
    SIMLOG="$ROOT/scalers/$d/sim_out/sim.log"
  fi
  printf "%-10s %-9s %-22s %s  %s\n" "$SIM" "$MODE" "$d" "$r" \
    "$(grep -h TB_RESULT "$SIMLOG" 2>/dev/null)"
done
exit $fail
