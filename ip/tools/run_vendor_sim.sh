#!/usr/bin/env bash
# Compile and run a scaler testbench with VCS, ModelSim, or Questa.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="$1"; shift
source "$ROOT/tools/tb_args.sh"
SIM="${SIM:-${SIMULATOR:-vcs}}"
MODULE="$ROOT/scalers/$IP"
TOP="tb_${IP}"
TB_DIR="$MODULE/tb/scripts"
OUT="$ROOT/build/vendor/$SIM/$IP"
mkdir -p "$OUT"
SRCS=(); while IFS= read -r file; do [ -n "$file" ] && SRCS+=("$TB_DIR/$file"); done < "$TB_DIR/build.f"
DEFINES=("+define+TB_MAX_W=$TB_MAX_W" "+define+TB_MAX_H=$TB_MAX_H" "${VDEFS[@]+${VDEFS[@]}}")

case "$SIM" in
  vcs)
    VCS_BIN="${VCS_BIN:-vcs}"
    command -v "$VCS_BIN" >/dev/null || { echo "vcs not found (set VCS_BIN)" >&2; exit 2; }
    VCS_FLAGS_ARR=(); read -r -a VCS_FLAGS_ARR <<< "${VCS_FLAGS:-}"
    "$VCS_BIN" -full64 -sverilog -top "$TOP" -I"$ROOT/scalers/scaler_tb_lib/src" +incdir+"$ROOT/scalers/$IP/tb/tests" \
      "${DEFINES[@]}" "${VCS_FLAGS_ARR[@]}" "${SRCS[@]}" -o "$OUT/$TOP.simv" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    (cd "$OUT" && "./$TOP.simv" "${PLUSARGS[@]}") | tee "$OUT/sim.log"
    ;;
  modelsim|questa|questasim)
    VLIB_BIN="${VLIB_BIN:-vlib}"; VLOG_BIN="${VLOG_BIN:-vlog}"; VSIM_BIN="${VSIM_BIN:-vsim}"
    command -v "$VLIB_BIN" >/dev/null || { echo "$SIM vlib not found (set VLIB_BIN)" >&2; exit 2; }
    command -v "$VLOG_BIN" >/dev/null || { echo "$SIM vlog not found (set VLOG_BIN)" >&2; exit 2; }
    command -v "$VSIM_BIN" >/dev/null || { echo "$SIM vsim not found (set VSIM_BIN)" >&2; exit 2; }
    (cd "$OUT" && "$VLIB_BIN" work)
    VLOG_FLAGS_ARR=(); read -r -a VLOG_FLAGS_ARR <<< "${VLOG_FLAGS:-}"
    "$VLOG_BIN" -sv -work "$OUT/work" +incdir+"$ROOT/scalers/scaler_tb_lib/src" +incdir+"$ROOT/scalers/$IP/tb/tests" \
      "${DEFINES[@]}" "${VLOG_FLAGS_ARR[@]}" "${SRCS[@]}" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    VSIM_FLAGS_ARR=(); read -r -a VSIM_FLAGS_ARR <<< "${VSIM_FLAGS:-}"
    "$VSIM_BIN" -c -work "$OUT/work" "${VSIM_FLAGS_ARR[@]}" "$TOP" \
      "${PLUSARGS[@]}" -do "run -all; quit -f" | tee "$OUT/sim.log"
    ;;
  *) echo "unsupported vendor simulator '$SIM'" >&2; exit 2 ;;
esac
grep -q "TB_RESULT: PASS" "$OUT/sim.log" || { echo "[$IP] SIMULATION FAILED" >&2; exit 1; }
echo "[$IP] PASSED ($SIM)"#!/usr/bin/env bash
# Compile/run one scaler testbench with VCS, ModelSim, or QuestaSim.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IP="$1"; shift
source "$ROOT/tools/tb_args.sh"
SIM="${SIM:-vcs}"
TOP="tb_${IP}"
MODULE="$ROOT/scalers/$IP"
TB_DIR="$MODULE/tb/scripts"
OUT="$ROOT/build/vendor/$SIM/$IP"
mkdir -p "$OUT"
SRCS=(); while IFS= read -r file; do [ -n "$file" ] && SRCS+=("$TB_DIR/$file"); done < "$TB_DIR/build.f"
DEFINES=("+define+TB_MAX_W=$TB_MAX_W" "+define+TB_MAX_H=$TB_MAX_H" "${VDEFS[@]+${VDEFS[@]}}")
case "$SIM" in
  vcs)
    VCS_BIN="${VCS_BIN:-vcs}"
    command -v "$VCS_BIN" >/dev/null || { echo "vcs not found (set VCS_BIN)" >&2; exit 2; }
    VCS_FLAGS_ARR=(); read -r -a VCS_FLAGS_ARR <<< "${VCS_FLAGS:-}"
    "$VCS_BIN" -full64 -sverilog -top "$TOP" -I"$ROOT/scalers/scaler_tb_lib/src" +incdir+"$ROOT/scalers/$IP/tb/tests" \
      "${DEFINES[@]}" "${VCS_FLAGS_ARR[@]}" "${SRCS[@]}" -o "$OUT/$TOP.simv" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    (cd "$OUT" && "./$TOP.simv" "${PLUSARGS[@]}") | tee "$OUT/sim.log"
    ;;
  modelsim|questasim)
    VLIB_BIN="${VLIB_BIN:-vlib}"; VLOG_BIN="${VLOG_BIN:-vlog}"; VSIM_BIN="${VSIM_BIN:-vsim}"
    command -v "$VLIB_BIN" >/dev/null || { echo "$SIM vlib not found (set VLIB_BIN)" >&2; exit 2; }
    command -v "$VLOG_BIN" >/dev/null || { echo "$SIM vlog not found (set VLOG_BIN)" >&2; exit 2; }
    command -v "$VSIM_BIN" >/dev/null || { echo "$SIM vsim not found (set VSIM_BIN)" >&2; exit 2; }
    (cd "$OUT" && "$VLIB_BIN" work)
    VLOG_FLAGS_ARR=(); read -r -a VLOG_FLAGS_ARR <<< "${VLOG_FLAGS:-}"
    "$VLOG_BIN" -sv -work "$OUT/work" +incdir+"$ROOT/scalers/scaler_tb_lib/src" +incdir+"$ROOT/scalers/$IP/tb/tests" \
      "${DEFINES[@]}" "${VLOG_FLAGS_ARR[@]}" "${SRCS[@]}" > "$OUT/build.log" 2>&1 \
      || { tail -40 "$OUT/build.log"; exit 1; }
    VSIM_FLAGS_ARR=(); read -r -a VSIM_FLAGS_ARR <<< "${VSIM_FLAGS:-}"
    "$VSIM_BIN" -c -work "$OUT/work" "${VSIM_FLAGS_ARR[@]}" "$TOP" \
      "${PLUSARGS[@]}" -do "run -all; quit -f" | tee "$OUT/sim.log"
    ;;
  *) echo "unsupported vendor simulator '$SIM' (use vcs, modelsim, or questasim)" >&2; exit 2 ;;
esac
grep -q "TB_RESULT: PASS" "$OUT/sim.log" || { echo "[$IP] SIMULATION FAILED" >&2; exit 1; }
echo "[$IP] PASSED ($SIM)"