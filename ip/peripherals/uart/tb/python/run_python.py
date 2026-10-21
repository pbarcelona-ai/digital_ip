"""Build and run the uart cocotb tests (uart_tb.py: the RTL against the golden model) at 100 MHz / 1 Mbaud with
4-word FIFOs and at 200 MHz / 2 Mbaud with py_soc's 2-word FIFOs. Run by scripts/run_sim.sh after the
SystemVerilog testbench. Environment: PYTHON_SIM (verilator, default, or icarus), UART_CYCLES, UART_SEED,
COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from uart_tb import CASES                                          # noqa: E402

SOURCES = build_f_sources(MODULE) + [TEST_DIR / "uart_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("uart", SOURCES, "uart_cocotb_top", "uart_tb", TEST_DIR, CASES, "UART_CASE")
