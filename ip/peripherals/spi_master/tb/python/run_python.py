"""Build and run the spi_master cocotb tests (spi_master_tb.py: the RTL against the golden model) in py_soc's
configuration (200 MHz, 10 MHz SCLK, 16-bit words, 2 chip selects, 2-word FIFOs) and a 24-bit, 4-chip-select
one. Run by scripts/run_sim.sh after the SystemVerilog testbench. Environment: PYTHON_SIM (verilator,
default, or icarus), SPI_CYCLES, SPI_SEED, COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from spi_master_tb import CASES                                    # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "spi_master_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("spi_master", SOURCES, "spi_master_cocotb_top", "spi_master_tb", TEST_DIR, CASES, "SPI_CASE")
