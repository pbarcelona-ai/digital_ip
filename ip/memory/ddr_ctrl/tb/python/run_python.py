"""Build and run the ddr_ctrl cocotb test (ddr_ctrl_tb.py: ddr_ctrl with ddr_mem against their golden models) for
the parameter sets of ddr_ctrl_tb.CASES. Run by scripts/run_sim.sh after the SystemVerilog testbench.
Environment: PYTHON_SIM (verilator, default, or icarus), DDRC_N, DDRC_SEED, DDRC_CASES (comma-separated case
names; default all), COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from ddr_ctrl_tb import CASES                                      # noqa: E402

SOURCES = build_f_sources(MODULE) + build_f_sources(MODULE.parent / "ddr_mem") + \
    [TEST_DIR / "ddr_ctrl_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("ddr_ctrl", SOURCES, "ddr_ctrl_cocotb_top", "ddr_ctrl_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("DDRC_CASES", ",".join(CASES)).split(",")},
              "DDRC_CASE")
