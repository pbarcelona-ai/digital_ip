#!/bin/bash
# ***************
# Filename: run.sh
# Author: FPGA Cores 4 U
# Description: Run frame_store_ddr cocotb tests via run.py
# Date: 2026-10-21
# ***************

set -euo pipefail

THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${THIS_DIR}/.."

# Default to small frames for speed; override with SMALL=0
SMALL="${SMALL:-1}"
export SMALL

# Pass through WAVES=1 to enable VCD dump
WAVES="${WAVES:-0}"
export WAVES

# Pass through SIM=icarus (default) or other simulator
SIM="${SIM:-icarus}"
export SIM

echo "Running frame_store_ddr cocotb tests (SMALL=${SMALL}, WAVES=${WAVES}, SIM=${SIM})"

exec python3 scripts/run.py "$@"