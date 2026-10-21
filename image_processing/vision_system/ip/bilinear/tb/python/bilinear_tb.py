"""cocotb test of bilinear against its model (ip/bilinear/model/bilinear_model.py): random corners and fractions
(0 and 255 included) every clock with random valid_in; valid_out and pixel_out 3 clocks later equal the model.
Environment: BIL_N (default 20000), BIL_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import bilinear_model as bm                                       # noqa: E402

CASES = {"default": {}}
N = int(os.environ.get("BIL_N", "20000"))
SEED = int(os.environ.get("BIL_SEED", "20261021"))


@cocotb.test()
async def test_bilinear_exact(dut):
    """Every output pixel equals the model, 3 clocks after its inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    dut.rst_n.value = 0
    dut.valid_in.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    hist = []
    n = 0
    for i in range(N + bm.LATENCY):
        await FallingEdge(dut.clk)
        v = int(rng.random() < 0.8)
        fx, fy = (rng.choice([0, 255, rng.randrange(256)]) for _ in range(2))
        px = [rng.choice([0, 0xFFFFFF, rng.getrandbits(24)]) for _ in range(4)]
        dut.valid_in.value, dut.fx.value, dut.fy.value = v, fx, fy
        dut.tl.value, dut.tr.value, dut.bl.value, dut.br.value = px
        hist.append((v, fx, fy, px))
        await Timer(1, unit="ns")
        if i >= bm.LATENCY:
            ev, efx, efy, epx = hist[i - bm.LATENCY]
            assert int(dut.valid_out.value) == ev, f"input {i - bm.LATENCY}: valid_out {dut.valid_out.value}"
            if ev:
                exp = bm.bilinear(efx, efy, *epx)
                assert int(dut.pixel_out.value) == exp, \
                    f"input {i - bm.LATENCY}: fx {efx} fy {efy} {[hex(p) for p in epx]}: rtl " \
                    f"{int(dut.pixel_out.value):#08x} model {exp:#08x}"
                n += 1
    dut._log.info("bilinear: %d pixels compared", n)
