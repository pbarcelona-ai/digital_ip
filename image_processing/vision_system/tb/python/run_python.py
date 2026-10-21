"""Build and run the vision_system cocotb tests (vision_system_tb.py: the RTL against the golden model; scripts/build.f paths are relative to src/). Environment:
PYTHON_SIM (verilator, default, or icarus), VS_GROUPS, VS_SEED, VS_CASES, COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

VS = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(VS.parents[1] / "ip" / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import run_cases                                  # noqa: E402
from vision_system_tb import CASES                                 # noqa: E402

SOURCES = [(VS / "src" / ln.strip()).resolve() for ln in open(VS / "scripts" / "build.f", encoding="utf-8")
           if ln.strip() and not ln.strip().startswith("#")] + [TEST_DIR / "vision_system_cocotb_top.sv"]

if __name__ == "__main__":
    run_cases("vision_system", SOURCES, "vision_system_cocotb_top", "vision_system_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("VS_CASES", ",".join(CASES)).split(",")},
              "VS_CASE")
