"""Build and run the blur_sharpen cocotb tests (blur_sharpen_tb.py: the RTL against the golden model) for the
parameter sets of blur_sharpen_tb.CASES. Run by scripts/run_sim.sh after the SystemVerilog testbench.
Environment: PYTHON_SIM (verilator, default, or icarus), BLSH_FRAMES, BLSH_SEED, BLSH_CASES (comma-separated
case names; default all), COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from blur_sharpen_tb import CASES                                    # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "blur_sharpen_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("blur_sharpen", SOURCES, "blur_sharpen_cocotb_top", "blur_sharpen_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("BLSH_CASES", ",".join(CASES)).split(",")},
              "BLSH_CASE")
