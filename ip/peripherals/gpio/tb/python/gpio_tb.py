"""cocotb tests of gpio against its golden model (ip/peripherals/gpio/model/gpio_model.py).

test_core_clock_exact: the logic (u_core, with the register map's W1C INT_STATUS in the wrapper) driven directly,
clock for clock: random pin levels (single pins toggling, bursts, glitches of one clock), OUT / SET / CLEAR /
TOGGLE writes, DIR, INT_EN / RISE_EN / FALL_EN, INT_STATUS clears (also in the clock an edge sets a bit). Every
clock OUT, IN, INT_STATUS, the pins (gpio_o, gpio_t) equal the model's, irq_o the model's condition of the clock
before (registered).
test_register_map: the block (u_top, pins low) over AXI4-Lite against the model's register map.
Environment: GPIO_CASE, GPIO_CYCLES (default 30000), GPIO_SEED.
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
import gpio_model                                                 # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"w32": dict(WIDTH=32), "w5": dict(WIDTH=5)}
CASE = os.environ.get("GPIO_CASE", "w32")
W = CASES[CASE]["WIDTH"]
MASK = (1 << W) - 1
CYCLES = int(os.environ.get("GPIO_CYCLES", "30000"))
SEED = int(os.environ.get("GPIO_SEED", "20261020"))


class Host:
    def __init__(self):
        self.sim = Sim()

    def update_irq(self):
        pass


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_out", "core_out_wr", "core_dir", "core_set", "core_set_wr", "core_clear", "core_clear_wr",
              "core_toggle", "core_toggle_wr", "core_int_en", "core_rise_en", "core_fall_en", "core_int_status_w1c",
              "core_int_status_wr", "gpio_i"):
        getattr(dut, n).value = 0
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic against the model, clock for clock (irq_o one clock after the condition)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    h = Host()
    pins = 0
    m = gpio_model.Gpio(h, board_in=lambda o, t: pins, width=W)
    cov = collections.Counter()
    regs = dict(DIR=0, INT_EN=0, RISE_EN=0, FALL_EN=0)
    prev_irq = 0
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        x = rng.random()
        if x < 0.15:
            pins ^= 1 << rng.randrange(W)
        elif x < 0.17:
            pins = rng.getrandbits(W)
        if rng.random() < 0.01:
            k = rng.choice(list(regs))
            regs[k] = rng.getrandbits(W)
        wr = {}
        if rng.random() < 0.05:
            wr[rng.choice(("out", "set", "clear", "toggle"))] = rng.getrandbits(W)
        st_wr, st = int(rng.random() < 0.03), rng.getrandbits(W)
        dut.gpio_i.value = pins
        dut.core_dir.value, dut.core_int_en.value = regs["DIR"], regs["INT_EN"]
        dut.core_rise_en.value, dut.core_fall_en.value = regs["RISE_EN"], regs["FALL_EN"]
        for n in ("out", "set", "clear", "toggle"):
            getattr(dut, f"core_{n}").value = wr.get(n, 0)
            getattr(dut, f"core_{n}_wr").value = int(n in wr)
        dut.core_int_status_w1c.value, dut.core_int_status_wr.value = st, st_wr
        await Timer(1, unit="ns")
        for k, v in regs.items():                                 # this clock's registers, then its events
            m.r.set(k, v)
        h.sim.advance(1)
        m.sample()                                                # this clock's pins
        r = dict(out=int(dut.core_sts_out.value), inp=int(dut.core_sts_in.value), ist=int(dut.core_int_status.value),
                 o=int(dut.gpio_o.value), t=int(dut.gpio_t.value), irq=int(dut.core_irq_o.value))
        mo = dict(out=m.r.sts("OUT", 0), inp=m.r.sts("IN", 0), ist=m.r.get("INT_STATUS"), o=m.out,
                  t=~regs["DIR"] & MASK, irq=prev_irq)
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        prev_irq = int(m.irq())
        for n, d in wr.items():
            m._w(n.upper(), 0, d)
            cov[n] += 1
        if st_wr:
            m.r.write(0x34, st)
        cov["edge"] += r["ist"] != 0
        cov["irq"] += r["irq"]
    for k in ("out", "set", "clear", "toggle", "edge", "irq"):
        assert cov[k], f"not covered: {k}"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(cov))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map (pins low)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    h = Host()
    m = gpio_model.Gpio(h, width=W)
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x38, 0xFC})
    for k in range(500):
        off = rng.choice(offs)
        h.sim.now += 10                                           # outputs settled between accesses
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:02X}"
            h.sim.advance(2)
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 500 accesses compared")
