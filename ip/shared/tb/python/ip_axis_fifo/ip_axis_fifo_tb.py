"""cocotb test of ip_axis_fifo against its golden model (ip/shared/model/ip_axis_fifo_model.py), clock for
clock: random s_tvalid / m_tready rates (bursts that fill the FIFO, idle stretches that drain it); every
clock s_tready, m_tvalid, the output word (data, last, user) and the level are compared with the model's
state of the same clock, then both take the clock's handshakes. Environment: FIFO_CASE, FIFO_CYCLES
(default 20000), FIFO_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

SHARED = Path(__file__).resolve().parents[3]                      # ip/shared
sys.path.insert(0, str(SHARED / "model"))
from ip_axis_fifo_model import AxisFifo                           # noqa: E402

CASES = {"d2": dict(DEPTH=2), "d4": dict(DEPTH=4), "d16": dict(DEPTH=16)}
CASE = os.environ.get("FIFO_CASE", "d4")
DEPTH = CASES[CASE]["DEPTH"]
CYCLES = int(os.environ.get("FIFO_CYCLES", "20000"))
SEED = int(os.environ.get("FIFO_SEED", "20261020"))


@cocotb.test()
async def test_clock_exact(dut):
    """The FIFO against the model, clock for clock."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    for n in ("s_tdata", "s_tlast", "s_tuser", "s_tvalid", "m_tready"):
        getattr(dut, n).value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    rng = random.Random(SEED)
    f = AxisFifo(DEPTH)
    cov = collections.Counter()
    p_in, p_out = 0.5, 0.5
    for cyc in range(CYCLES):
        await FallingEdge(dut.clk)
        if rng.random() < 0.02:                                   # a new traffic pattern
            p_in, p_out = rng.choice(((0.9, 0.1), (0.1, 0.9), (0.5, 0.5), (1.0, 1.0), (0.0, 0.3), (0.7, 0.0)))
        valid, ready = int(rng.random() < p_in), int(rng.random() < p_out)
        word = (rng.getrandbits(8), rng.getrandbits(1), rng.getrandbits(1))
        dut.s_tdata.value, dut.s_tlast.value, dut.s_tuser.value = word
        dut.s_tvalid.value, dut.m_tready.value = valid, ready
        await Timer(1, unit="ns")
        f.sync(cyc)
        r = dict(s_tready=int(dut.s_tready.value), m_tvalid=int(dut.m_tvalid.value), level=int(dut.level.value))
        mo = dict(s_tready=int(not f.full()), m_tvalid=int(f.tvalid()), level=f.level())
        if r["m_tvalid"]:
            r["word"] = (int(dut.m_tdata.value), int(dut.m_tlast.value), int(dut.m_tuser.value))
            mo["word"] = f.o_q
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        if valid:
            f.push(cyc, word)
        if ready:
            f.take(cyc)
        cov["full"] += f.full()
        cov["level_max"] = max(cov["level_max"], r["level"])
        cov["both"] += valid and ready and r["s_tready"] and r["m_tvalid"]
    assert cov["full"] and cov["both"] and cov["level_max"] == DEPTH + 2, f"coverage {dict(cov)}"
    dut._log.info("%d clocks compared, %s", CYCLES, dict(cov))
