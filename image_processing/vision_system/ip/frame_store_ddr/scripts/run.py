#!/usr/bin/env python3
"""
run.py -- build and simulate frame_store_ddr with cocotb + Icarus Verilog.

Usage:
    python3 run.py                  full-size frames (64x64)
    SMALL=1 python3 run.py          small frames (8x8), fast
    WAVES=1 python3 run.py          also write a waveform

Sources: src/frame_store_ddr.sv and its dependencies, plus the cocotb top.
"""

import os
import subprocess
import sys
from cocotb_tools.runner import get_runner

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(THIS_DIR, "..", "src")
MODEL_DIR = os.path.join(THIS_DIR, "..", "model")
TB_DIR = os.path.join(THIS_DIR, "..", "tb")
LIB_DIR = os.path.join(THIS_DIR, "..", "..", "..", "..", "..", "ip")
IF_DIR = os.path.join(LIB_DIR, "shared", "src", "interfaces")
DDR_DIR = os.path.join(LIB_DIR, "memory")

# Interface files
IFACES = [
    os.path.join(IF_DIR, "axil_if.sv"),
    os.path.join(IF_DIR, "frame_store_if.sv"),
    os.path.join(DDR_DIR, "ddr_ctrl", "src", "include", "ddr_ctrl_regs_if.sv"),
]

# DDR controller and memory
DDR_SRCS = [
    os.path.join(DDR_DIR, "ddr_ctrl", "src", "ddr_ctrl.sv"),
    os.path.join(DDR_DIR, "ddr_mem", "src", "ddr_mem.sv"),
]

# Fallthrough FIFO (used by ddr_ctrl)
FIFO_SRCS = [
    os.path.join(LIB_DIR, "fifo", "fallthrough_fifo", "src", "fallthrough_fifo.sv"),
]

# DUT source
DUT_SRC = os.path.join(SRC_DIR, "frame_store_ddr.sv")

# Cocotb testbench top
TOP = "frame_store_ddr_cocotb_top"
TB_TOP = os.path.join(TB_DIR, f"{TOP}.sv")

# Model for reference
MODEL_SRC = os.path.join(MODEL_DIR, "frame_store_ddr_model.py")


def get_sources(small=True):
    """Return the RTL source list in dependency order."""
    sources = IFACES + DDR_SRCS + FIFO_SRCS + [DUT_SRC, TB_TOP]
    # Verify all sources exist
    for src in sources:
        if not os.path.exists(src):
            raise FileNotFoundError(f"Missing source: {src}")
    return sources


def main():
    sim = os.environ.get("SIM", "icarus")
    if sim != "icarus":
        sys.exit("run.py: SIM must be icarus; other simulators not configured")

    small = os.environ.get("SMALL", "1") == "1"
    waves = os.environ.get("WAVES", "0") == "1"

    runner = get_runner(sim)
    build_dir = os.path.join(TB_DIR, "sim_build")

    # Parameters for the testbench
    params = {}
    if small:
        params.update({
            "FRAME_WIDTH": "8",
            "FRAME_HEIGHT": "8",
            "CACHE_LINES": "4",
            "CACHE_LINE_W": "6",
            "DDR_DATA_W": "64",
            "DDR_ADDR_W": "18",
            "DDR_ID_W": "2",
            "DDR_BANK_W": "2",
            "DDR_ROW_W": "8",
            "DDR_COL_W": "4",
            "DDR_MEM_WORDS": "4096",
            "PIX_W": "16",
            "DDR_REF_MAX": "576",
        })
    else:
        params.update({
            "FRAME_WIDTH": "64",
            "FRAME_HEIGHT": "64",
            "CACHE_LINES": "4",
            "CACHE_LINE_W": "6",
            "DDR_DATA_W": "64",
            "DDR_ADDR_W": "18",
            "DDR_ID_W": "2",
            "DDR_BANK_W": "2",
            "DDR_ROW_W": "8",
            "DDR_COL_W": "4",
            "DDR_MEM_WORDS": "4096",
            "PIX_W": "16",
            "DDR_REF_MAX": "576",
        })

    runner.build(
        sources=get_sources(small),
        hdl_toplevel=TOP,
        always=True,
        timescale=("1ns", "1ps"),
        parameters=params,
    )

    runner.test(
        hdl_toplevel=TOP,
        test_module="frame_store_ddr_tb",
        test_dir=TB_DIR,
        waves=waves,
    )


if __name__ == "__main__":
    main()