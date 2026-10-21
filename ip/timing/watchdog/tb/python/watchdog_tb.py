"""cocotb tests of watchdog against its golden model (ip/timing/watchdog/model/watchdog_model.py).

test_core_clock_exact: the logic (u_core) with its register interface driven directly, clock for clock: CTRL
(enable, window mode, lock), TIMEOUT / PRESCALE / PRETIMEOUT / WINDOW_OPEN changes (also while counting and
after LOCK, which freezes them), good / early / bad kicks, STATUS clears, expiries with the reset request.
Every clock CTRL, STATUS, COUNT, irq_o and wdt_reset_o equal the model's. Runs restart from reset now and then
(LOCK is undone only by reset).
test_register_map: the block (u_top) over AXI4-Lite against the model's register map (disabled).
Environment: WDT_CYCLES (default 60000), WDT_SEED.
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
import watchdog_model as wm                                       # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"rc16": dict(RESET_CYCLES=16), "rc1": dict(RESET_CYCLES=1)}
CASE = os.environ.get("WDT_CASE", "rc16")
RC = CASES[CASE]["RESET_CYCLES"]
CYCLES = int(os.environ.get("WDT_CYCLES", "60000"))
SEED = int(os.environ.get("WDT_SEED", "20261020"))


class Host:
    def __init__(self):
        self.sim = Sim()

    def update_irq(self):
        pass


async def reset(dut, regs):
    dut.aresetn.value = 0
    for n in ("core_ctrl", "core_ctrl_wr", "core_kick", "core_kick_wr", "core_status", "core_status_wr"):
        getattr(dut, n).value = 0
    for k, v in regs.items():
        getattr(dut, "core_" + k.lower()).value = v
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic against the model, clock for clock, with restarts from reset."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    rng = random.Random(SEED)
    cov = collections.Counter()
    cyc = 0
    while cyc < CYCLES:
        regs = dict(TIMEOUT=1000, PRESCALE=0, PRETIMEOUT=0, WINDOW_OPEN=0)
        await reset(dut, regs)
        h = Host()
        m = wm.Wdt(h, RC)
        await FallingEdge(dut.aclk)                               # the first clock after reset
        h.sim.now = 0
        for _ in range(rng.randint(2000, 12000)):
            ctrl_wr = kick_wr = st_wr = 0
            ctrl = kick = st = 0
            x = rng.random()
            if x < 0.004:
                ctrl, ctrl_wr = rng.choice((1, 1, 3, 0, 5, 7, 1)), 1
                cov["lock"] += ctrl & 4 and not m.lock
            elif x < 0.012:
                k = rng.choice(list(regs))
                regs[k] = rng.choice((0, 1, 2, 3, 5, 8, 20, 50)) if k != "PRESCALE" else rng.choice((0, 0, 1, 2, 4))
            elif x < 0.03:
                kick, kick_wr = (wm.KEY if rng.random() < 0.85 else rng.getrandbits(32)), 1
            elif x < 0.035:
                st, st_wr = rng.getrandbits(4), 1
            dut.core_ctrl.value, dut.core_ctrl_wr.value = ctrl, ctrl_wr
            dut.core_kick.value, dut.core_kick_wr.value = kick, kick_wr
            dut.core_status.value, dut.core_status_wr.value = st, st_wr
            for k, v in regs.items():
                getattr(dut, "core_" + k.lower()).value = v
            await Timer(1, unit="ns")
            for k, v in regs.items():
                m.r.set(k, v)
            if any(m.r.get(k) != m.lat[k] for k in regs):         # a register changed: its copy next clock
                m._edge_due(h.sim.now)
            r = dict(ctrl=int(dut.core_sts_ctrl.value), st=int(dut.core_sts_status.value),
                     cnt=int(dut.core_sts_count.value), irq=int(dut.core_irq_o.value), rst=int(dut.core_wdt_reset_o.value))
            mo = dict(ctrl=m.r.sts("CTRL", 0), st=m.r.sts("STATUS", 0), cnt=m.r.sts("COUNT", 0), irq=int(m.irq()),
                      rst=m.reset_at(h.sim.now))
            assert r == mo, f"clock {cyc} (regs {regs}): rtl {r} model {mo}"
            if ctrl_wr:
                m._w("CTRL", 0, ctrl)
            if kick_wr:
                m._w("KICK", 0, kick)
            if st_wr:
                m._w("STATUS", 0, st)
            cov["exp"] += (r["st"] >> 1) & 1
            cov["early"] += (r["st"] >> 2) & 1
            cov["key"] += (r["st"] >> 3) & 1
            cov["pre"] += r["st"] & 1
            cov["rst"] += r["rst"]
            await FallingEdge(dut.aclk)
            h.sim.advance(1)
            cyc += 1
        cov["runs"] += 1
    for k in ("lock", "exp", "early", "key", "pre", "rst"):
        assert cov[k], f"not covered: {k} ({dict(cov)})"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(cov))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map (CTRL not enabled)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut, {})
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    h = Host()
    m = wm.Wdt(h, RC)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x30, 0xFC})
    for k in range(500):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if off == 0x10:
                d &= 2                                            # never enabled or locked here
            if off == 0x24:
                d = rng.choice((wm.KEY, d))
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:02X}"
            h.sim.advance(3)
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 500 accesses compared")
