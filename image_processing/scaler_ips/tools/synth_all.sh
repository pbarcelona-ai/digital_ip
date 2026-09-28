#!/usr/bin/env bash
# Runs <module>/synth.sh for every synthesizable module and prints a summary
# (top-level totals from each yosys/utilization_hier.rpt).
# Usage: tools/synth_all.sh [module ...] [-- synth.sh options]
#   e.g. tools/synth_all.sh                              all modules, defaults
#        tools/synth_all.sh scaler_lanczos -- -p LINE_BUF=1 -p MAX_W=1920
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODS=(); OPTS=(); seen=0
for a in "$@"; do
  if [ "$a" = "--" ]; then seen=1; continue; fi
  if [ $seen = 1 ]; then OPTS+=("$a"); else MODS+=("$a"); fi
done
[ ${#MODS[@]} -eq 0 ] && MODS=(axil_regbus axil_split scaler_dda scaler_ctrl banked_framebuf
  scaler_nearest scaler_bilinear scaler_edge_directed scaler_polyphase scaler_bicubic
  scaler_lanczos scaler_mip scaler_trilinear scaler_anisotropic sharpen_cas spatial_upscaler)
printf "%-22s %-6s %8s %8s %8s %8s %8s %8s %8s %6s\n" Module Result LUT LUTRAM FF CARRY MUXF BRAM36 DSP Time
fail=0
for m in "${MODS[@]}"; do
  rpt="$ROOT/$m/yosys/utilization_hier.rpt"
  rm -f "$rpt"          # never show results left over from an earlier run
  if "$ROOT/$m/synth.sh" ${OPTS[@]+"${OPTS[@]}"} > /dev/null 2>&1; then r=PASS; else r=FAIL; fail=1; fi
  tot=$(awk -v m="$m" '$1==m {print $2, $3, $4, $5, $6, $7, $8; exit}' "$rpt" 2>/dev/null)
  t=$(awk '/^Run time/ {print $4 "s"}' "$rpt" 2>/dev/null)
  [ -n "$tot" ] || tot="- - - - - - -"
  [ -n "$t" ] || t="-"
  printf "%-22s %-6s %8s %8s %8s %8s %8s %8s %8s %6s\n" "$m" "$r" $tot "$t"
done
exit $fail
