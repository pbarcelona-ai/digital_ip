"""Build and run the i2c_master cocotb tests (i2c_master_tb.py: the RTL against the golden model) with a
16-word FIFO (100 MHz, 100 kHz), py_soc's configuration (200 MHz, 400 kHz, 2-word FIFOs) and 512-word FIFOs.
Run by scripts/run_sim.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or
icarus), I2C_CYCLES, I2C_SEED, COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from i2c_master_tb import CASES                                    # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "i2c_master_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("i2c_master", SOURCES, "i2c_master_cocotb_top", "i2c_master_tb", TEST_DIR, CASES, "I2C_CASE")
