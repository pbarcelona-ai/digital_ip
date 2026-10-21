"""cocotb test of mulq_s against its model (ip/mulq/model/mulq_s_model.py): random signed 32-bit operands every
clock (with the extremes -2**31, 2**31 - 1, 0, +-1, +-2**16 mixed in); s 2 clocks later equals (a * b) >>> 16
exactly, and barrel_pkg's qsat48 of it equals qmul. Environment: MULQ_N (operand pairs, default 20000),
MULQ_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import barrel_pkg_model as bp                                     # noqa: E402
import mulq_s_model as mm                                         # noqa: E402

CASES = {"default": {}}
N = int(os.environ.get("MULQ_N", "20000"))
SEED = int(os.environ.get("MULQ_SEED", "20261021"))
EDGE = [-(1 << 31), (1 << 31) - 1, 0, 1, -1, 1 << 16, -(1 << 16), (1 << 16) - 1]


def operand(rng):
    if rng.random() < 0.2:
        return rng.choice(EDGE)
    return rng.choice([rng.randrange(-(1 << 31), 1 << 31), rng.randrange(-(1 << 20), 1 << 20)])


@cocotb.test()
async def test_mulq_exact(dut):
    """Every product equals the model, 2 clocks after its operands."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    hist = []
    sat = 0
    for i in range(N + mm.LATENCY):
        await FallingEdge(dut.clk)
        a, b = operand(rng), operand(rng)
        dut.a.value, dut.b.value = a & 0xFFFFFFFF, b & 0xFFFFFFFF
        hist.append((a, b))
        await Timer(1, unit="ns")
        if i >= mm.LATENCY:
            ea, eb = hist[i - mm.LATENCY]
            exp = mm.mulq_s(ea, eb)
            got = dut.s.value.to_signed()
            assert got == exp, f"pair {i - mm.LATENCY}: a {ea} b {eb}: rtl {got} model {exp}"
            assert bp.qsat48(got) == bp.qsat(ea * eb)
            sat += int(bp.qsat48(got) != got)
    dut._log.info("mulq_s: %d products compared, %d saturate in qsat48", N, sat)
    assert sat, "no saturating product covered"
