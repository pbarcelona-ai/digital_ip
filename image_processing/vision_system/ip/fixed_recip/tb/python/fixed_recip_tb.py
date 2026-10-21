"""cocotb test of fixed_recip against its model (ip/fixed_recip/model/fixed_recip_model.py): operands 0, 1, 2,
powers of two, Q16.16 values around 1.0, frame sizes and random 32-bit values; each start is checked for the
result, done one clock wide after edge W + 2, busy high exactly from the start edge to that edge, and starts
pulsed while busy are ignored. Environment: RECIP_N (default 600), RECIP_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import fixed_recip_model as fm                                    # noqa: E402

CASES = {"default": {}}
N = int(os.environ.get("RECIP_N", "600"))
SEED = int(os.environ.get("RECIP_SEED", "20261021"))


def operand(rng, i):
    fixed = [0, 1, 2, 3, 0xFFFFFFFF, 0x80000000, 1 << 16, (1 << 16) - 1, (1 << 16) + 1, 320 << 16, 720 << 16]
    if i < len(fixed):
        return fixed[i]
    return rng.choice([1 << rng.randrange(32), rng.randrange(1 << 12, 1 << 26), rng.getrandbits(32)])


@cocotb.test()
async def test_recip_exact(dut):
    """Every reciprocal, its done pulse and busy equal the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    dut.rst_n.value = 0
    dut.start.value = 0
    dut.operand.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    edge = fm.done_edge()
    ignored = 0
    for k in range(N):
        await FallingEdge(dut.clk)
        op = operand(rng, k)
        dut.start.value, dut.operand.value = 1, op
        await FallingEdge(dut.clk)                            # start taken at the edge before this point
        dut.start.value = 0
        for j in range(1, edge + 3):
            await Timer(1, unit="ns")
            if j <= edge:                                     # iteration j shows the registers after edge j - 1
                assert int(dut.busy.value) == 1 and int(dut.done.value) == 0, \
                    f"operand {op:#x}: busy {dut.busy.value} done {dut.done.value} {j} clocks after start"
            elif j == edge + 1:
                assert int(dut.done.value) == 1, f"operand {op:#x}: no done {edge} edges after start"
                assert int(dut.result.value) == fm.recip(op), \
                    f"operand {op:#x}: rtl {int(dut.result.value):#x} model {fm.recip(op):#x}"
            else:
                assert int(dut.done.value) == 0 and int(dut.busy.value) == 0, "done longer than one clock"
            if j == 5 and rng.random() < 0.3:                 # a start while busy: ignored
                dut.start.value, dut.operand.value = 1, rng.getrandbits(32)
                ignored += 1
            elif j == 6:
                dut.start.value, dut.operand.value = 0, op
            await FallingEdge(dut.clk)
    dut._log.info("fixed_recip: %d reciprocals compared, %d starts while busy ignored", N, ignored)
    assert ignored, "no start while busy covered"
