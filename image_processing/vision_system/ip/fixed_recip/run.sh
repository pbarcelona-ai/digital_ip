#!/usr/bin/env bash
# Builds and runs fixed_recip's self-checking testbench. No external
# package dependency -- this IP is fully standalone.
#
# Usage:
#   ./run.sh
set -e
cd "$(dirname "$0")"

iverilog -g2012 -o tb_fixed_recip.vvp fixed_recip.sv tb_fixed_recip.sv
vvp tb_fixed_recip.vvp
