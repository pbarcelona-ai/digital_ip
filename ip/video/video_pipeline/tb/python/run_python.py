"""Build and run the video_pipeline cocotb test (video_pipeline_tb.py: the ISP against the golden model) with the
test's build configuration (video_pipeline_cocotb_config.sv first). Environment: PYTHON_SIM (verilator, default,
or icarus), VP_GROUPS, VP_SEED, VP_CASES, COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
sys.path.insert(0, str(TEST_DIR))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402
from video_pipeline_tb import CASES                                # noqa: E402

SOURCES = ([TEST_DIR / "video_pipeline_cocotb_config.sv"] + build_f_sources(MODULE)
           + [TEST_DIR / "video_pipeline_cocotb_top.sv"])

if __name__ == "__main__":
    run_cases("video_pipeline", SOURCES, "video_pipeline_cocotb_top", "video_pipeline_tb", TEST_DIR,
              {k: v for k, v in CASES.items() if k in os.environ.get("VP_CASES", ",".join(CASES)).split(",")},
              "VP_CASE")
