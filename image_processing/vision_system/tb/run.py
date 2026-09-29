#!/usr/bin/env python3
"""
run.py -- build and simulate vision_system with cocotb + Icarus Verilog.

Usage:
    python3 run.py                  full-size frames (480x480 / 480x720 / 720x480)
    SMALL_FRAMES=1 python3 run.py   small frames (48x48 / 32x56 / 56x32), fast
    WAVES=1 python3 run.py          also write a waveform (view with Surfer:
                                    ../synth/view_waves.sh <sim_build>/*.vcd)

Produces (in tb/work/):
    test.jpg / test.ppm       the original (input, or auto-generated chart)
    warped.jpg / warped.ppm   synthetically distorted version of the original
    corrected.jpg / corrected.ppm   the DUT's corrected output
"""
import os
import sys
from cocotb_tools.runner import get_runner

THIS_DIR = os.path.dirname(os.path.abspath(__file__))
RTL_DIR = os.path.join(THIS_DIR, "..", "src")
IP_DIR = os.path.join(THIS_DIR, "..", "ip")

SOURCES = [
    os.path.join(RTL_DIR, "barrel_pkg.sv"),
    os.path.join(RTL_DIR, "distortion_model_pkg.sv"),
    os.path.join(IP_DIR, "fixed_recip", "fixed_recip.sv"),
    os.path.join(IP_DIR, "mulq", "mulq_s.sv"),
    os.path.join(IP_DIR, "coord_gen", "coord_gen.sv"),
    os.path.join(IP_DIR, "bilinear", "bilinear.sv"),
    os.path.join(IP_DIR, "bicubic", "bicubic.sv"),
    os.path.join(IP_DIR, "frame_buffer", "frame_buffer.sv"),
    os.path.join(RTL_DIR, "axis_in_ctrl.sv"),
    os.path.join(RTL_DIR, "axis_out_ctrl.sv"),
    os.path.join(RTL_DIR, "axi_lite_regs.sv"),
    os.path.join(RTL_DIR, "vision_system.sv"),
]


def main():
    sim = os.environ.get("SIM", "icarus")
    runner = get_runner(sim)
    runner.build(
        sources=SOURCES,
        hdl_toplevel="vision_system",
        always=True,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel="vision_system",
        test_module="test_vision_system",
        waves=os.environ.get("WAVES", "0") == "1",
    )


if __name__ == "__main__":
    main()
