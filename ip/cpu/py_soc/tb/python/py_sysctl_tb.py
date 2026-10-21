"""cocotb tests of py_sysctl against its golden model (ip/cpu/py_soc/model/py_sysctl_model.py).

test_core_clock_exact: the logic (u_core) with its register interface driven directly, clock for clock: the
model's time is the RTL's CYCLES (counting from the system reset); random TIMER_CMP writes (in the past, now,
the next clocks, far ahead, across the 2**32 wrap of the compare), TIMER_STATUS clears (also in the clock
REACHED is set), TIMER_CTRL, CORE_RESET, CLK_EN, RESET_CAUSE clears. Every clock: TIMER_STATUS, timer_irq_o,
CYCLES, RESET_CAUSE, BOOT_STATUS, SOC_ID, CLK_STATUS, core_rst_n_o, clk_en_o.
test_register_map: the block (u_top) over AXI4-Lite against the model's register map (reset values, random
writes and reads of every offset; CYCLES and TIMER_STATUS excluded from the random reads, their timing is
the clock-exact test's).
Environment: SYSCTL_CYCLES (default 30000), SYSCTL_SEED.
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
import py_sysctl_model                                            # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"soc": dict(NCLK=4)}
CYCLES = int(os.environ.get("SYSCTL_CYCLES", "30000"))
SEED = int(os.environ.get("SYSCTL_SEED", "20261020"))
COV = collections.Counter()


class Host:
    """The model's host (py_soc): event queue, core reset and clock enables it is told about."""

    def __init__(self):
        self.sim = Sim()
        self.clk_en = 0
        self.core_rst = 0

    def core_reset(self, v):
        self.core_rst = v

    def update_irq(self):
        pass


async def reset(dut):
    dut.aresetn.value = 0
    dut.por_n.value = 0
    for n in ("core_reset_cause", "core_reset_cause_wr", "core_core_reset", "core_clk_en", "core_timer_cmp",
              "core_timer_cmp_wr", "core_timer_ctrl", "core_timer_status", "core_timer_status_wr"):
        getattr(dut, n).value = 0
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.por_n.value = 1
    await FallingEdge(dut.aclk)


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic against the model, clock for clock (CYCLES = the model's time)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    h = Host()
    m = py_sysctl_model.SysCtl(h)
    regs = dict(CORE_RESET=0, CLK_EN=0, TIMER_CMP=0, TIMER_CTRL=0)
    dut.aresetn.value = 1
    await FallingEdge(dut.aclk)
    await Timer(1, unit="ns")
    h.sim.now = int(dut.core_sts_cycles.value)                    # the model's time origin: CYCLES
    for cyc in range(CYCLES):
        if cyc:
            await FallingEdge(dut.aclk)
            h.sim.advance(1)                                      # model time = CYCLES of this clock
        cmp_wr = st_wr = rc_wr = 0
        st = rc = 0
        x = rng.random()
        if x < 0.01:
            now = h.sim.now
            regs["TIMER_CMP"] = rng.choice((now, now + 1, now + 2, now - 1, now - 5, now + rng.randint(3, 400),
                                            now + (1 << 31) - 1, now + (1 << 31), now - (1 << 31))) & 0xFFFFFFFF
            cmp_wr = 1
            COV["cmp"] += 1
        elif x < 0.02:
            st, st_wr = rng.getrandbits(1), 1
        elif x < 0.025:
            rc, rc_wr = rng.getrandbits(2), 1
        if rng.random() < 0.005:
            regs["TIMER_CTRL"] ^= 1
        if rng.random() < 0.002:
            regs["CORE_RESET"] ^= 1
            regs["CLK_EN"] = rng.getrandbits(4)
        dut.core_timer_cmp.value, dut.core_timer_cmp_wr.value = regs["TIMER_CMP"], cmp_wr
        dut.core_timer_status.value, dut.core_timer_status_wr.value = st, st_wr
        dut.core_reset_cause.value, dut.core_reset_cause_wr.value = rc, rc_wr
        dut.core_timer_ctrl.value, dut.core_core_reset.value = regs["TIMER_CTRL"], regs["CORE_RESET"]
        dut.core_clk_en.value = regs["CLK_EN"]
        await Timer(1, unit="ns")
        for k, v in regs.items():
            m.r.set(k, v)
        sts = lambda n: m.r.sts(n, 0)                             # noqa: E731
        r = dict(st=int(dut.core_sts_timer_status.value), irq=int(dut.core_timer_irq_o.value),
                 cycles=int(dut.core_sts_cycles.value), cause=int(dut.core_sts_reset_cause.value),
                 boot=int(dut.core_sts_boot_status.value), id=int(dut.core_sts_soc_id.value),
                 clk=int(dut.core_sts_clk_status.value), rst=int(dut.core_core_rst_n_o.value),
                 en=int(dut.core_clk_en_o.value))
        mo = dict(st=sts("TIMER_STATUS"), irq=int(m.timer_irq()), cycles=sts("CYCLES"), cause=sts("RESET_CAUSE"),
                  boot=sts("BOOT_STATUS"), id=sts("SOC_ID"), clk=sts("CLK_STATUS"), rst=regs["CORE_RESET"],
                  en=regs["CLK_EN"])
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        COV["reached"] += r["st"]
        COV["irq"] += r["irq"]
        COV["clear_on_set"] += st_wr and st and r["st"] == 0 and m.timer_gen % 2 == 0
        if cmp_wr:
            m._w("TIMER_CMP", 0, regs["TIMER_CMP"])
        if st_wr:
            m._w("TIMER_STATUS", 0, st)
        if rc_wr:
            m._w("RESET_CAUSE", 0, rc)
    assert COV["cmp"] and COV["reached"] and COV["irq"], f"coverage {dict(COV)}"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(COV))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    dut.aresetn.value = 1
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    h = Host()
    m = py_sysctl_model.SysCtl(h)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x38, 0x3C, 0xFC})
    timed = {0x18, 0x34}                                          # CYCLES, TIMER_STATUS: clock-exact test
    for off in offs:
        d, resp = await axi.read(off)
        md = m.r.read(off)
        if off in timed:
            assert resp == md[1], f"reset 0x{off:02X}: resp {resp} model {md[1]}"
        else:
            assert (d, resp) == md, f"reset 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for k in range(600):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if off == 0x2C:
                d |= 1 << 31                                      # far ahead: no REACHED during the test
            resp = await axi.write(off, d)
            mresp = m.r.write(off, d)
            assert resp == mresp, f"write 0x{off:02X} = {d:x}: rtl resp {resp} model {mresp}"
            assert int(dut.top_core_rst_n_o.value) == m.r.get("CORE_RESET")
            assert int(dut.top_clk_en_o.value) == m.r.get("CLK_EN")
        elif off not in timed:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):                                            # the last writes applied before the end
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 600 accesses compared")
