#!/usr/bin/env bash
# Compile and run a categorized IP with VCS, ModelSim, or Questa.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -ge 1 ] || { echo "usage: $0 <ip> [--vcd]" >&2; exit 2; }
IP="$1"; shift; lookup "$IP"
if [[ "$CAT" == scalers ]]; then
  exec "$REPO/tools/run_vendor_sim.sh" "$IP" "$@"
fi
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --vcd) ARGS+=("+vcd") ;;
    --wave) echo "waveform auto-launch is not configured for $SIM" >&2 ;;
    --lint) echo "--lint is not supported by this vendor compile hook" >&2; exit 2 ;;
    *) ARGS+=("$arg") ;;
  esac
done
OUT="${BUILD_ROOT:-$REPO/build}/vendor/$SIM/$IP"
mkdir -p "$OUT"
# COV=1 (scripts/run_cov.sh with a vendor SIM): native code coverage -> $OUT/cov.vdb (VCS) / $OUT/cov.ucdb (Questa)
COV_VCS=(); COV_VLOG=(); COV_VSIM=(); COV_DO=""
if [ "${COV:-0}" = 1 ]; then
  COV_VCS=(-cm line+cond+fsm+tgl+branch -cm_dir "$OUT/cov.vdb")
  COV_VLOG=(+cover=bcefst); COV_VSIM=(-coverage); COV_DO="coverage save -onexit $OUT/cov.ucdb; "
fi
SRCS=(); while IFS= read -r file; do [ -n "$file" ] && SRCS+=("$file"); done < <(filelist "$IP")
case " ${SRCS[*]} " in *ip_axil_regs.sv*) ;; *) SRCS+=("$REPO/shared/src/common/ip_axil_regs.sv") ;; esac
TB_SRCS=(); while IFS= read -r file; do [ -n "$file" ] && TB_SRCS+=("$file"); done < <(filelist "$IP" tb/scripts/build.f)
# test tasks: tb/tests/<name>_tests.sv next to every testbench file compiled (`included)
TB_INC=(+incdir+"$IPDIR/tb/tests"); for f in "${TB_SRCS[@]}"; do [ -d "$(dirname "$f")/tests" ] && TB_INC+=(+incdir+"$(dirname "$f")/tests"); done

case "$SIM" in
  vcs)
    VCS_BIN="${VCS_BIN:-vcs}"
    command -v "$VCS_BIN" >/dev/null || { echo "vcs not found (set VCS_BIN)" >&2; exit 2; }
    VCS_FLAGS_ARR=(); read -r -a VCS_FLAGS_ARR <<< "${VCS_FLAGS:-}"
    "$VCS_BIN" -full64 -sverilog -top "$TB" -o "$OUT/$TB.simv" "${TB_INC[@]}" \
      "${VCS_FLAGS_ARR[@]}" ${COV_VCS[@]+"${COV_VCS[@]}"} "${SRCS[@]}" "${TB_SRCS[@]}" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    (cd "$OUT" && "./$TB.simv" ${COV_VCS[@]+"${COV_VCS[@]}"} "${ARGS[@]}") | tee "$OUT/sim.log"
    ;;
  modelsim|questa|questasim)
    VLIB_BIN="${VLIB_BIN:-vlib}"; VLOG_BIN="${VLOG_BIN:-vlog}"; VSIM_BIN="${VSIM_BIN:-vsim}"
    command -v "$VLIB_BIN" >/dev/null || { echo "$SIM vlib not found (set VLIB_BIN)" >&2; exit 2; }
    command -v "$VLOG_BIN" >/dev/null || { echo "$SIM vlog not found (set VLOG_BIN)" >&2; exit 2; }
    command -v "$VSIM_BIN" >/dev/null || { echo "$SIM vsim not found (set VSIM_BIN)" >&2; exit 2; }
    (cd "$OUT" && "$VLIB_BIN" work)
    VLOG_FLAGS_ARR=(); read -r -a VLOG_FLAGS_ARR <<< "${VLOG_FLAGS:-}"
    "$VLOG_BIN" -sv -work "$OUT/work" "${TB_INC[@]}" "${VLOG_FLAGS_ARR[@]}" ${COV_VLOG[@]+"${COV_VLOG[@]}"} \
      "${SRCS[@]}" "${TB_SRCS[@]}" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    VSIM_FLAGS_ARR=(); read -r -a VSIM_FLAGS_ARR <<< "${VSIM_FLAGS:-}"
    "$VSIM_BIN" -c -work "$OUT/work" "${VSIM_FLAGS_ARR[@]}" ${COV_VSIM[@]+"${COV_VSIM[@]}"} "$TB" \
      "${ARGS[@]}" -do "${COV_DO}run -all; quit -f" | tee "$OUT/sim.log"
    ;;
  *) echo "unsupported vendor simulator '$SIM'" >&2; exit 2 ;;
esac
grep -Eq "TEST PASSED|TB_RESULT: PASS" "$OUT/sim.log" || { echo "[$IP] SIMULATION FAILED" >&2; exit 1; }
echo "[$IP] PASSED ($SIM)"
if [[ -f "$IPDIR/tb/python/run_python.py" ]]; then
  PYTHON_SIM="${PYTHON_SIM:-${PYTHON_SIMULATOR:-verilator}}" python3 "$IPDIR/tb/python/run_python.py"
fi
