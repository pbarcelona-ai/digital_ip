"""Build and run the NPU cocotb tests (tb/python/*_tb.py) for their parameter sets. Environment: PYTHON_SIM
(verilator, default, or icarus), NPU_TESTS (comma-separated test modules; default all), NPU_SEED, COV_DIR."""
from __future__ import annotations

import os
import sys
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2]
TEST_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(MODULE.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import build_f_sources, run_cases                 # noqa: E402

SRC = MODULE / "src"
# test module -> (top, sources, cases)
TESTS = {
    "npu_dma_tb": ("npu_dma", [SRC / "npu_dma.sv"], {"dma": {}, "dma_rq2": {"RQ": 2}}),
    "npu_ops_tb": ("npu_cocotb_top", build_f_sources(MODULE) + [TEST_DIR / "npu_cocotb_top.sv"],
                   {"pe8": {"PE_P": 8, "PE_O": 8}, "pe64": {"PE_P": 64, "PE_O": 64}}),
}

if __name__ == "__main__":
    sel = os.environ.get("NPU_TESTS", ",".join(TESTS)).split(",")
    for name in sel:
        top, srcs, cases = TESTS[name]
        run_cases(f"npu_{name}", srcs, top, name, TEST_DIR, cases, "NPU_CASE")
