"""Build and run the mac_array cocotb test for the parameter sets of mac_array_tb.CASES."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases
from mac_array_tb import CASES

# Sources: mac.sv + mac_array.sv
SOURCES = [
    str(MODULE / "src" / "mac.sv"),
    str(MODULE / "src" / "mac_array.sv"),
]

if __name__ == "__main__":
    run_cases("mac_array", SOURCES, "mac_array", "mac_array_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("MACA_CASES", ",".join(CASES)).split(",")},
              "MACA_CASE")

