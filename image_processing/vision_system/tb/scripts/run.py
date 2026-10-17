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
import subprocess
import sys
from cocotb_tools.runner import get_runner

THIS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RTL_DIR = os.path.join(THIS_DIR, "..", "src")
IP_DIR = os.path.join(THIS_DIR, "..", "ip")
INCLUDE_DIR = os.path.join(THIS_DIR, "..", "include")
LIB_DIR = os.path.join(THIS_DIR, "..", "..", "..", "ip")
IF_DIR = os.path.join(LIB_DIR, "shared", "src", "interfaces")
IFACES = [os.path.join(IF_DIR, f"{n}.sv") for n in ("axis_if", "axil_if", "regbus_if")] + [
    os.path.join(RTL_DIR, "include", "vision_system_regs_if.sv")]

SOURCES = [
    os.path.join(INCLUDE_DIR, "barrel_pkg.sv"),
    os.path.join(INCLUDE_DIR, "distortion_model_pkg.sv"),
    *IFACES,
    os.path.join(IP_DIR, "fixed_recip", "src", "fixed_recip.sv"),
    os.path.join(IP_DIR, "mulq", "src", "mulq_s.sv"),
    os.path.join(IP_DIR, "coord_gen", "src", "coord_gen.sv"),
    os.path.join(IP_DIR, "bilinear", "src", "bilinear.sv"),
    os.path.join(IP_DIR, "bicubic", "src", "bicubic.sv"),
    os.path.join(IP_DIR, "frame_buffer", "src", "frame_buffer.sv"),
    os.path.join(IP_DIR, "ext_frame_buffer", "src", "ext_frame_buffer.sv"),
    os.path.join(RTL_DIR, "axis_in_ctrl.sv"),
    os.path.join(RTL_DIR, "axis_out_ctrl.sv"),
    os.path.join(LIB_DIR, "bus", "axi4_lite_slave", "src", "axi4_lite_slave.sv"),
    os.path.join(RTL_DIR, "include", "vision_system_regs.sv"),
    os.path.join(RTL_DIR, "axi_lite_regs.sv"),
    os.path.join(RTL_DIR, "vision_system.sv"),
]
TOP = "vision_system_syn"      # discrete-port wrapper: cocotb drives plain ports, not interfaces


def wrapper(build_dir):
    """vision_system_syn.sv: vision_system with its interface ports as discrete <port>_<member> ports
    (ip/scripts/syn_wrap.py), the same names the tests drive (s_axis_tdata, s_axil_awaddr, ...)."""
    os.makedirs(build_dir, exist_ok=True)
    out = os.path.join(build_dir, f"{TOP}.sv")
    with open(out, "w") as fh:
        subprocess.run([sys.executable, os.path.join(LIB_DIR, "scripts", "syn_wrap.py"),
                        os.path.join(RTL_DIR, "vision_system.sv"), "vision_system", *IFACES],
                       stdout=fh, check=True)
    return out


def main():
    sim = os.environ.get("SIM", "icarus")
    runner = get_runner(sim)
    build_dir = os.path.join(THIS_DIR, "..", "sim_build")
    runner.build(
        sources=SOURCES + [wrapper(build_dir)],
        hdl_toplevel=TOP,
        always=True,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    runner.test(
        hdl_toplevel=TOP,
        test_module="test_vision_system",
        test_dir=THIS_DIR,
        waves=os.environ.get("WAVES", "0") == "1",
    )


if __name__ == "__main__":
    main()
