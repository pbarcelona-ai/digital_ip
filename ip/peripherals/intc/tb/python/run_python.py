"""Build and run the intc cocotb tests (intc_tb.py: the RTL against the golden model) for NUM_IRQ 17 (py_soc),
32 and 1. Run by scripts/run_sim.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator,
default, or icarus), INTC_CYCLES, INTC_SEED, COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from intc_tb import CASES                                          # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "intc_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("intc", SOURCES, "intc_cocotb_top", "intc_tb", TEST_DIR, CASES, "INTC_CASE")
