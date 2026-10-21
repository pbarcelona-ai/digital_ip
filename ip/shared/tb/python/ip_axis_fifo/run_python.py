"""Build and run the ip_axis_fifo cocotb test (ip_axis_fifo_tb.py: the RTL against the golden model) for
DEPTH 2 (py_soc's peripherals), 4 and 16. Environment: PYTHON_SIM (verilator, default, or icarus),
FIFO_CYCLES, FIFO_SEED, COV_DIR."""
from __future__ import annotations

import sys
from pathlib import Path

TEST_DIR = Path(__file__).resolve().parent
SHARED = TEST_DIR.parents[2]                                       # ip/shared
sys.path.insert(0, str(TEST_DIR.parent))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import run_cases                                  # noqa: E402
from ip_axis_fifo_tb import CASES                                  # noqa: E402

SOURCES = [SHARED / "src/interfaces/axis_if.sv", SHARED / "src/fifo/ip_axis_fifo.sv",
           TEST_DIR / "ip_axis_fifo_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("ip_axis_fifo", SOURCES, "ip_axis_fifo_cocotb_top", "ip_axis_fifo_tb", TEST_DIR, CASES, "FIFO_CASE")
