#!/usr/bin/env bash
# ***************
# Filename: run_cov.sh
# Author: FPGA Cores 4 U
# Description: Run any simulation command with code coverage.
#   SIM=iverilog/verilator (default): the iverilog / vvp shims in tools/cov
#   are put first on PATH, so the command's Icarus compile is rebuilt with
#   verilator --coverage (line, branch, expression, toggle); the coverage
#   of all its runs is then merged and summarized per RTL file
#   (tools/cov/cov_report.py). Verilator-based Python (cocotb) testbenches
#   add --coverage themselves when COV_DIR is set.
#   SIM=vcs|modelsim|questa|questasim: the vendor run scripts get COV=1 and
#   collect native coverage; the databases are merged into <out_dir>.
# Date: 2026-10-09
#
# Usage: scripts/run_cov.sh <out_dir> <command> [args...]
#   e.g. scripts/run_cov.sh build/coverage/uart scripts/run_sim.sh uart
#   Results in <out_dir>: summary.txt, summary.csv, merged.dat,
#   coverage.info (LCOV), annotated/ (Verilator); urgReport/ (VCS);
#   merged.ucdb, coverage.txt (Questa). Exit status is the command's.
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO/.tools"
[ $# -ge 2 ] || { echo "usage: $0 <out_dir> <command> [args...]" >&2; exit 2; }
mkdir -p "$1"; OUT="$(cd "$1" && pwd)"; shift
SIM="${SIM:-${SIMULATOR:-iverilog}}"
# vendor run directories: scripts/run_vendor_sim.sh honours BUILD_ROOT, tools/run_vendor_sim.sh (scalers) does not
VENDOR_DIRS=("${BUILD_ROOT:-$REPO/build}/vendor/$SIM"); [ "${BUILD_ROOT:-$REPO/build}" = "$REPO/build" ] || VENDOR_DIRS+=("$REPO/build/vendor/$SIM")
shopt -s nullglob

case "$SIM" in
  vcs)
    export COV=1 SIM; for d in "${VENDOR_DIRS[@]}"; do rm -rf "$d"/*/cov.vdb; done
    "$@"; RC=$?
    DBS=(); for d in "${VENDOR_DIRS[@]}"; do DBS+=("$d"/*/cov.vdb); done
    [ ${#DBS[@]} -gt 0 ] || { echo "run_cov: no VCS coverage databases in ${VENDOR_DIRS[*]}" >&2; exit 1; }
    "${URG_BIN:-urg}" -dir "${DBS[@]}" -dbname "$OUT/merged.vdb" -report "$OUT/urgReport" -format both || RC=${RC/#0/1}
    echo "coverage report: $OUT/urgReport/dashboard.txt"
    exit "$RC" ;;
  modelsim|questa|questasim)
    export COV=1 SIM; for d in "${VENDOR_DIRS[@]}"; do rm -f "$d"/*/cov.ucdb; done
    "$@"; RC=$?
    DBS=(); for d in "${VENDOR_DIRS[@]}"; do DBS+=("$d"/*/cov.ucdb); done
    [ ${#DBS[@]} -gt 0 ] || { echo "run_cov: no coverage databases in ${VENDOR_DIRS[*]}" >&2; exit 1; }
    VCOVER="${VCOVER_BIN:-vcover}"
    "$VCOVER" merge "$OUT/merged.ucdb" "${DBS[@]}" && "$VCOVER" report -details -output "$OUT/coverage.txt" "$OUT/merged.ucdb" || RC=${RC/#0/1}
    echo "coverage report: $OUT/coverage.txt"
    exit "$RC" ;;
esac

command -v verilator >/dev/null || { echo "verilator not found: coverage needs Verilator >= 5" >&2; exit 2; }
rm -rf "$OUT/data" "$OUT/annotated"; mkdir -p "$OUT/data"
export COV_DIR="$OUT/data" SIM=iverilog PATH="$REPO/tools/cov:$PATH"
"$@"; RC=$?
python3 "$REPO/tools/cov/cov_report.py" "$OUT" --root "$(cd "$REPO/.." && pwd)" || RC=${RC/#0/1}
exit "$RC"
