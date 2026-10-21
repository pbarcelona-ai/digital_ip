"""Build and run the object_tracker cocotb tests (object_tracker_tb.py: the RTL against the golden model). Run by
scripts/run_sim.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or icarus),
OTRK_FRAMES, OTRK_SEED, COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from object_tracker_tb import CASES                                # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "object_tracker_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("object_tracker", SOURCES, "object_tracker_cocotb_top", "object_tracker_tb", TEST_DIR, CASES,
              "OTRK_CASE")
