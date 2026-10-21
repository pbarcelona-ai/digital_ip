"""cocotb test of frame_buffer against its model (ip/frame_buffer/model/frame_buffer_model.py): the store filled,
then random writes and four-port reads every clock (rd_en and wr_en random, the same address written and read
in one clock included); the read data one clock after each read equal the model (old data on a read during a
write) and hold without rd_en. Environment: FB_N (default 20000), FB_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import frame_buffer_model as fm                                   # noqa: E402

CASES = {"d256": dict(DEPTH=256, ADDR_W=8)}
CASE = os.environ.get("FB_CASE", "d256")
N = int(os.environ.get("FB_N", "20000"))
SEED = int(os.environ.get("FB_SEED", "20261021"))


@cocotb.test()
async def test_frame_buffer_exact(dut):
    """Every read equals the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    depth = CASES[CASE]["DEPTH"]
    m = fm.FrameBuffer(depth)
    ports = [(dut.rd_addr0, dut.rd_data0), (dut.rd_addr1, dut.rd_data1), (dut.rd_addr2, dut.rd_data2),
             (dut.rd_addr3, dut.rd_data3)]
    exp = None
    same = 0
    for i in range(depth + N):
        await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        if exp is not None:
            got = [int(d.value) for _, d in ports]
            assert got == exp, f"clock {i}: rtl {[hex(v) for v in got]} model {[hex(v) for v in exp]}"
        if i < depth:
            we, wa, wd, re = 1, i, rng.getrandbits(24), 0
        else:
            we, wa, wd = int(rng.random() < 0.5), rng.randrange(depth), rng.getrandbits(24)
            re = int(rng.random() < 0.7)
        addrs = [rng.randrange(depth) for _ in range(4)]
        if we and re and rng.random() < 0.2:
            addrs[rng.randrange(4)] = wa
            same += 1
        dut.wr_en.value, dut.wr_addr.value, dut.wr_data.value, dut.rd_en.value = we, wa, wd, re
        for (a, _), v in zip(ports, addrs):
            a.value = v
        rd = m.clock(we, wa, wd, re, addrs)
        exp = rd if i >= depth else None                          # compared once the store is filled
    dut._log.info("frame_buffer: %d clocks compared, %d reads of the address being written", N, same)
