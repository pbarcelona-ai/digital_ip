"""cocotb test of bicubic against its model (ip/bicubic/model/bicubic_model.py): random 4 x 4 taps (flat, edges,
noise; 0 and 255 included) and fractions every clock with random valid_in - fractions in [0, 1) (0 and 1 - 2**-16
included) and, now and then, any 32-bit value (the weights' saturation and wrap); valid_out and pixel_out 18
clocks later equal the model. Environment: BIC_N (default 10000), BIC_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import bicubic_model as bm                                        # noqa: E402

CASES = {"default": {}}
N = int(os.environ.get("BIC_N", "10000"))
SEED = int(os.environ.get("BIC_SEED", "20261021"))


def frac(rng):
    r = rng.random()
    if r < 0.05:
        return rng.getrandbits(32)                                # out of range: saturation / wrap
    if r < 0.15:
        return rng.choice([0, 0xFFFF, 0x8000])
    return rng.randrange(1 << 16)


def taps(rng):
    kind = rng.choice(["noise", "edge", "flat", "extreme"])
    if kind == "flat":
        v = rng.getrandbits(24)
        return [[v] * 4 for _ in range(4)]
    if kind == "edge":
        a, b = rng.getrandbits(24), rng.getrandbits(24)
        return [[a if c < 2 else b for c in range(4)] for _ in range(4)]
    if kind == "extreme":
        return [[rng.choice([0, 0xFFFFFF]) for _ in range(4)] for _ in range(4)]
    return [[rng.getrandbits(24) for _ in range(4)] for _ in range(4)]


@cocotb.test()
async def test_bicubic_exact(dut):
    """Every output pixel equals the model, 18 clocks after its inputs."""
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
        tx, ty, p = frac(rng), frac(rng), taps(rng)
        dut.valid_in.value, dut.tx_q16.value, dut.ty_q16.value = v, tx, ty
        for r in range(4):
            for c in range(4):
                getattr(dut, f"p{r}{c}").value = p[r][c]
        hist.append((v, tx, ty, p))
        await Timer(1, unit="ns")
        if i >= bm.LATENCY:
            ev, etx, ety, ep = hist[i - bm.LATENCY]
            assert int(dut.valid_out.value) == ev, f"input {i - bm.LATENCY}: valid_out"
            if ev:
                exp = bm.bicubic(etx, ety, ep)
                assert int(dut.pixel_out.value) == exp, \
                    f"input {i - bm.LATENCY}: tx {etx:#x} ty {ety:#x}: rtl {int(dut.pixel_out.value):#08x} " \
                    f"model {exp:#08x}"
                n += 1
    dut._log.info("bicubic: %d pixels compared", n)
