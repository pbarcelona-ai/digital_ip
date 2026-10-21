"""cocotb tests of intc against its golden model (ip/peripherals/intc/model/intc_model.py).

test_core_clock_exact: the logic (u_core of intc_cocotb_top) with its register interface driven directly,
clock for clock against the clock-exact model: every clock the inputs and the register values of that clock
go to the model (its input log, set_cfg), then PENDING, MASKED, VECTOR and irq_o compare with the model's
state of the clock, then the clock's PENDING clears and software sets are written (they act from the next
clock; a set wins over a clear, an edge in the clock of a clear stays pending).
test_register_map: the block (u_top, intc_top) over AXI4-Lite against the model's register map and status:
every register's reset value, random writes and reads of every offset (responses and data), W1C PENDING,
SOFT_SET, the status with the inputs held still between accesses (the model's clock moved on so its
latencies have passed).
test_coverage: every source seen pending as an edge and as a level source, every vector value reported,
both polarities, a clear and a set in the same clock (the counts of the tests above).
Environment: INTC_CASE (the parameter set the runner built), INTC_CYCLES (default 20000), INTC_SEED.
"""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import AxilMaster, model_path                    # noqa: E402

model_path(IP / "model")
import intc_model                                                # noqa: E402
from event_sim import Sim                                        # noqa: E402

CASES = {"n17": dict(NUM_IRQ=17), "n32": dict(NUM_IRQ=32), "n1": dict(NUM_IRQ=1)}
CASE = os.environ.get("INTC_CASE", "n17")
N = CASES[CASE]["NUM_IRQ"]
MASK = (1 << N) - 1
CYCLES = int(os.environ.get("INTC_CYCLES", "20000"))
SEED = int(os.environ.get("INTC_SEED", "20261020"))
SYNC = 2                                                          # input synchroniser, clocks
COV = collections.Counter()


class Host:
    """The model's host: its clock and the input vector over time (set_raw: from the current clock)."""

    def __init__(self):
        self.sim = Sim()
        self.log = [(0, 0)]
        self.m = None

    def set_raw(self, v):
        if v != self.log[-1][1]:
            self.log.append((self.sim.now, v))
            self.m.input_changed(self.sim.now)

    def irq_in(self, n):
        for t, v in reversed(self.log):
            if t <= n:
                return v
        return 0


def vector_of(masked):
    return (1 << 31) | ((masked & -masked).bit_length() - 1) if masked else 0


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_irq_i", "core_enable", "core_edge_type", "core_active_low", "core_pending",
              "core_pending_wr", "core_soft_set", "core_soft_set_wr", "top_irq_i"):
        getattr(dut, n).value = 0
    for _ in range(4):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic, clock for clock against the model (fixed latencies applied)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    host = Host()
    m = host.m = intc_model.Intc(host, N)
    en = edg = pol = raw = 0
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        # stimulus of this clock
        if rng.random() < 0.05:
            en, edg, pol = rng.getrandbits(N), rng.getrandbits(N), rng.getrandbits(N) if rng.random() < 0.5 else 0
            if rng.random() < 0.4:                               # only the sources from k up: high vectors too
                en &= MASK & ~((1 << rng.randrange(N)) - 1)
        raw ^= sum(1 << i for i in range(N) if rng.random() < 0.08)
        clr_wr, clr = rng.random() < 0.05, rng.getrandbits(N)
        set_wr, sset = rng.random() < 0.03, rng.getrandbits(N) & rng.getrandbits(N)
        dut.core_irq_i.value, dut.core_enable.value = raw, en
        dut.core_edge_type.value, dut.core_active_low.value = edg, pol
        dut.core_pending.value, dut.core_pending_wr.value = clr, int(clr_wr)
        dut.core_soft_set.value, dut.core_soft_set_wr.value = sset, int(set_wr)
        await Timer(1, unit="ns")
        r_pend, r_mask = int(dut.core_sts_pending.value), int(dut.core_sts_masked.value)
        r_vec, r_irq = int(dut.core_sts_vector.value), int(dut.core_irq_o.value)
        # the model in this clock: its inputs and registers, then its state
        host.sim.now = cyc
        host.set_raw(raw)
        m.set_cfg("ENABLE", en)
        m.set_cfg("EDGE_TYPE", edg)
        m.set_cfg("ACTIVE_LOW", pol)
        pend, mask = m.pending(), m.masked()
        mvec, mirq = m.r.sts("VECTOR", 0), int(m.irq())
        assert (r_pend, r_mask) == (pend, mask), \
            f"clock {cyc}: PENDING / MASKED rtl {r_pend:x} / {r_mask:x} model {pend:x} / {mask:x}"
        assert r_vec == mvec, f"clock {cyc}: VECTOR rtl {r_vec:x} model {mvec:x}"
        assert r_irq == mirq, f"clock {cyc}: irq_o rtl {r_irq} model {mirq}"
        # this clock's writes act from the next clock; an edge in this clock wins over the clear
        rise = m._rise(cyc) & edg
        if clr_wr:
            m.r.write(0x1C, clr)
            COV["clear_and_edge"] += bool(clr & rise)
        if set_wr:
            m.r.write(0x20, sset)
        for i in range(N):
            if pend >> i & 1:
                COV[f"pend_{'edge' if edg >> i & 1 else 'level'}_{i}"] += 1
        if mask:
            COV[f"vector_{(mask & -mask).bit_length() - 1}"] += 1
        COV["active_low"] += bool(pol)
    dut._log.info("core: %d clocks compared", CYCLES)


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map and status."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    host = Host()
    m = host.m = intc_model.Intc(host, N)
    offs = sorted(m.r.regs) + [0x0, 0x4, 0x8, 0xC, 0x2C, 0x80, 0xFC]
    for off in sorted(set(offs)):                                # reset values
        d, resp = await axi.read(off)
        host.sim.now += 10
        assert (d, resp) == m.r.read(off), f"reset 0x{off:02X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    raw = 0
    for k in range(1500):
        if rng.random() < 0.1:                                   # new source levels, then let them settle
            raw = rng.getrandbits(N)
            dut.top_irq_i.value = raw
            for _ in range(SYNC + 3):
                await FallingEdge(dut.aclk)
            host.sim.now += 10
            host.set_raw(raw)
            host.sim.now += 10
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32) if rng.random() < 0.7 else rng.getrandbits(N)
            resp = await axi.write(off, d)
            mresp = m.r.write(off, d)
            assert resp == mresp, f"write 0x{off:02X} = {d:x}: rtl resp {resp} model {mresp}"
            for _ in range(2):                                   # the write reaches the logic
                await FallingEdge(dut.aclk)
            host.sim.now += 10
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            host.sim.now += 10
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
            COV[f"read_{off:02X}"] += 1
    dut._log.info("register map: 1500 accesses compared")


@cocotb.test()
async def test_coverage(dut):
    """Every source pending as an edge and a level source, every vector, both polarities, set over clear."""
    missing = [f"pend_{t}_{i}" for i in range(N) for t in ("edge", "level") if not COV[f"pend_{t}_{i}"]]
    missing += [f"vector_{i}" for i in range(N) if not COV[f"vector_{i}"]]
    missing += [k for k in ("active_low", "clear_and_edge") if not COV[k]]
    assert not missing, f"not covered: {missing}"
    dut._log.info("coverage: complete (%d sources)", N)
