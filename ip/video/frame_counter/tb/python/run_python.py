"""Build and run the frame_counter cocotb tests (frame_counter_tb.py: the RTL against the golden model) for the
parameter sets of frame_counter_tb.CASES. Run by scripts/run_sim.sh after the SystemVerilog testbench.
Environment: PYTHON_SIM (verilator, default, or icarus), FCNT_CYCLES, FCNT_SEED, FCNT_CASES (comma-separated case
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
from frame_counter_tb import CASES                                 # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "frame_counter_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("frame_counter", SOURCES, "frame_counter_cocotb_top", "frame_counter_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("FCNT_CASES", ",".join(CASES)).split(",")},
              "FCNT_CASE")
