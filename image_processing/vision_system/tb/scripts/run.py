#!/usr/bin/env python3
"""
run.py -- build and simulate vision_system with cocotb + Icarus Verilog.

Usage:
    python3 run.py                  full-size frames (480x480 / 480x720 / 720x480)
    SMALL_FRAMES=1 python3 run.py   small frames (48x48 / 32x56 / 56x32), fast
    WAVES=1 python3 run.py          also write a waveform (view with Surfer:
                                    ../synth/view_waves.sh <sim_build>/*.vcd)

Sources: scripts/build.f (the RTL list every flow shares) and the discrete-port wrapper from
ip/scripts/syn_wrap.py.

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
LIB_DIR = os.path.join(THIS_DIR, "..", "..", "..", "ip")
IF_DIR = os.path.join(LIB_DIR, "shared", "src", "interfaces")
IFACES = [os.path.join(IF_DIR, f"{n}.sv") for n in ("axis_if", "axil_if", "regbus_if")] + [
    os.path.join(RTL_DIR, "include", "vision_system_regs_if.sv")]


def build_f_sources():
    """The RTL file list of scripts/build.f (its paths are relative to src/), in order."""
    with open(os.path.join(THIS_DIR, "..", "scripts", "build.f"), encoding="utf-8") as fh:
        return [os.path.normpath(os.path.join(RTL_DIR, ln.strip())) for ln in fh
                if ln.strip() and not ln.strip().startswith("#")]


SOURCES = build_f_sources()
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
    if sim != "icarus":
        sys.exit("run.py: SIM must be icarus (the build arguments are Icarus's); tb/python runs Verilator")
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
