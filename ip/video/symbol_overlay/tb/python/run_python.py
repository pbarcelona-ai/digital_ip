"""Build and run the symbol_overlay cocotb tests (symbol_overlay_tb.py: the RTL against the golden model) for
the parameter sets of symbol_overlay_tb.CASES (FONT_DIR: the smooth font's ROM files in src/include). Run by
scripts/run_sim.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or icarus),
OVL_FRAMES, OVL_SEED, OVL_CASES (comma-separated case names; default all), COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from symbol_overlay_tb import CASES, FONT_DIR                      # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "symbol_overlay_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("symbol_overlay", SOURCES, "symbol_overlay_cocotb_top", "symbol_overlay_tb", TEST_DIR,
              {k: dict(v, FONT_DIR=f'"{FONT_DIR}"') for k, v in CASES.items()
               if k in os.environ.get("OVL_CASES", ",".join(CASES)).split(",")}, "OVL_CASE")
