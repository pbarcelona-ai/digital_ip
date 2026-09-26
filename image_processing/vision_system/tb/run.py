#!/usr/bin/env python3
"""
run.py -- build and simulate lens_distortion_correction with cocotb + Icarus Verilog.

Usage:
    python3 run.py

Produces (in tb/work/):
    test.jpg / test.ppm       the original (input, or auto-generated chart)
    warped.jpg / warped.ppm   synthetically distorted version of the original
    corrected.jpg / corrected.ppm   the DUT's corrected output
"""
import os
import sys
from cocotb_tools.runner import get_runner

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.join(THIS_DIR, "..", "rtl")
IP_DIR = os.path.join(THIS_DIR, "..", "ip")

SOURCES = [
    os.path.join(RTL_DIR, "barrel_pkg.sv"),
    os.path.join(RTL_DIR, "distortion_model_pkg.sv"),
    os.path.join(IP_DIR, "fixed_recip", "fixed_recip.sv"),
    os.path.join(IP_DIR, "coord_gen", "coord_gen.sv"),
    os.path.join(IP_DIR, "bilinear", "bilinear.sv"),
    os.path.join(IP_DIR, "bicubic", "bicubic.sv"),
    os.path.join(IP_DIR, "frame_buffer", "frame_buffer.sv"),
    os.path.join(RTL_DIR, "axis_in_ctrl.sv"),
    os.path.join(RTL_DIR, "axis_out_ctrl.sv"),
    os.path.join(RTL_DIR, "axi_lite_regs.sv"),
    os.path.join(RTL_DIR, "lens_distortion_correction.sv"),
]


def main():
    sim = os.environ.get("SIM", "icarus")
    runner = get_runner(sim)
    runner.build(
        sources=SOURCES,
        hdl_toplevel="lens_distortion_correction",
        always=True,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="lens_distortion_correction",
        test_module="test_lens_distortion_correction",
    )


if __name__ == "__main__":
    main()
