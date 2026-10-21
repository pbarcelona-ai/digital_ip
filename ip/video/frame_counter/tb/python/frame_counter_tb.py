"""cocotb tests of frame_counter against its model (ip/video/frame_counter/model/frame_counter_model.py).

test_core_clock_exact: the logic (u_core) with its register interface driven directly, clock for clock against
FrameCounterCore: random markers (several channels in one clock, one channel in consecutive clocks: a pending
event overwritten), IRQ_EN / EV_EN / STATUS values, CLEAR pulses (also with a marker of the cleared channel in
the same clock), EVENT_POP pulses (pop, overflow clear, both, on an empty and a full log); in every clock irq_o,
the status set, EVENT, EVENT_TIME, COUNT[0..NCH-1] and TIME equal the model's.
test_register_map: frame_counter_top through AXI4-Lite: the ID block, reset values and read-back of every
register against the register model; then markers on top_eof_i with the core model stepped every clock (the
register values the test wrote): COUNT, STATUS (W1C), irq_o, EVENT / EVENT_TIME through pops, the overflow
and its clear equal the model's.
Environment: FCNT_CASE (the parameter set the runner built), FCNT_CYCLES (default 40000), FCNT_SEED."""
from __future__ import annotations

import collections
import os
import random
import sys
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

IP = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(IP.parents[1] / "shared" / "tb" / "python"))
from cocotb_lib import AxilMaster, model_path                    # noqa: E402

model_path(IP / "model")
import frame_counter_model as fm                                 # noqa: E402
from regs import RegMap, ip_regs                                 # noqa: E402

CASES = {"n5": dict(NCH=5, EVQ=8, TS_DIV=3), "n8": dict(NCH=8, EVQ=2, TS_DIV=1), "n1": dict(NCH=1, EVQ=4, TS_DIV=2)}
CASE = os.environ.get("FCNT_CASE", "n5")
P = CASES[CASE]
CYCLES = int(os.environ.get("FCNT_CYCLES", "40000"))
SEED = int(os.environ.get("FCNT_SEED", "20261021"))
A = dict(IRQ_EN=0x18, STATUS=0x1C, CLEAR=0x20, EVENT=0x24, EVENT_TIME=0x28, EVENT_POP=0x2C, COUNT=0x30, TIME=0x50,
         EV_EN=0x54)
COV = collections.Counter()
CORE_IN = ("core_eof_i", "core_irq_en", "core_ev_en", "core_status", "core_clear", "core_clear_wr", "core_event_pop",
           "core_event_pop_wr", "top_eof_i")


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.rst_n.value = 0
    for n in CORE_IN:
        getattr(dut, n).value = 0
    for _ in range(3):
        await FallingEdge(dut.clk)
    dut.rst_n.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic against FrameCounterCore, clock for clock."""
    await reset(dut)
    rng = random.Random(SEED)
    n = P["NCH"]
    full = (1 << n) - 1
    m = fm.FrameCounterCore(n, P["EVQ"], P["TS_DIV"])
    m.clock()                                                     # the edge after reset, before the first sample
    irq_en = ev_en = status = 0
    rate = 0.05
    for cyc in range(CYCLES):
        await FallingEdge(dut.clk)
        if rng.random() < 0.002:
            rate = rng.choice([0.0, 0.02, 0.1, 0.5])
        eof = 0
        for i in range(n):
            if rng.random() < rate:
                eof |= 1 << i
        if rng.random() < 0.01:
            eof = full                                            # every channel in one clock
        if rng.random() < 0.01:
            irq_en, ev_en = rng.getrandbits(n), rng.choice([full, full, rng.getrandbits(n)])
        status = (status | eof) & full
        if rng.random() < 0.02:
            status &= ~rng.getrandbits(n)
        clr_wr = int(rng.random() < 0.01)
        clr = rng.getrandbits(n)
        pop_wr = int(rng.random() < rng.choice([0.05, 0.3]))
        pop = rng.choice([1, 1, 1, 2, 3, 0])
        ins = dict(core_eof_i=eof, core_irq_en=irq_en, core_ev_en=ev_en, core_status=status, core_clear=clr,
                   core_clear_wr=clr_wr, core_event_pop=pop, core_event_pop_wr=pop_wr)
        for k, v in ins.items():
            getattr(dut, k).value = v
        await Timer(1, unit="ns")
        o = m.clock(eof, irq_en, ev_en, status, clr_wr, clr, pop_wr, pop)
        cnt = int(dut.core_sts_count.value)
        r = dict(irq=int(dut.core_irq_o.value), status_set=int(dut.core_sts_status_set.value),
                 event=int(dut.core_sts_event.value), event_time=int(dut.core_sts_event_time.value),
                 time=int(dut.core_sts_time.value), count=[(cnt >> (32 * i)) & 0xFFFFFFFF for i in range(n)])
        mo = {k: o[k] for k in r}
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        COV["events"] += int(o["event"] >> 31)
        COV["overflow"] += o["ovf"]
        COV["full_log"] += int(len(m.q) == P["EVQ"])
        COV["clear_with_marker"] += int(clr_wr and bool(clr & eof))
        COV["multi"] += int(bin(eof).count("1") > 1)
    dut._log.info("%s core: %d clocks compared, coverage %s", CASE, CYCLES, dict(COV))
    for k in ("events", "overflow", "full_log", "clear_with_marker"):
        assert COV[k], f"not covered: {k}"
    if n > 1:
        assert COV["multi"], "not covered: multi"


@cocotb.test()
async def test_register_map(dut):
    """frame_counter_top through AXI4-Lite against the register model and the core model."""
    await reset(dut)
    rng = random.Random(SEED + 1)
    cov = collections.Counter()
    n = P["NCH"]
    full = (1 << n) - 1
    regmap = RegMap(ip_regs(fm.__file__, "frame_counter"), {"NCH": n})
    axi = AxilMaster(dut, dut.clk)
    offs = sorted(set(regmap.regs) | {0x0, 0x4, 0x8, 0xC, 0x10, 0x14, 0x58, 0xFC})
    for off in offs:
        d, resp = await axi.read(off)
        if off == A["TIME"]:
            assert resp == 0
            continue
        assert (d, resp) == regmap.read(off), f"reset 0x{off:02X}: rtl {d:#x}/{resp} model {regmap.read(off)}"
    for off in (A["IRQ_EN"], A["EV_EN"]):
        for _ in range(8):
            v = rng.getrandbits(32)
            assert await axi.write(off, v) == regmap.write(off, v)
            d, _ = await axi.read(off)
            assert d == regmap.read(off)[0], f"0x{off:02X} read back {d:#x}"
    # markers against the core model, stepped every clock with the register values written
    await axi.write(A["CLEAR"], full)
    await axi.write(A["EVENT_POP"], 2)
    while True:                                                   # empty the log
        d, _ = await axi.read(A["EVENT"])
        if not d >> 31:
            break
        await axi.write(A["EVENT_POP"], 1)
    await axi.write(A["STATUS"], full)
    await axi.write(A["IRQ_EN"], full)
    await axi.write(A["EV_EN"], full)
    for _ in range(3):
        await RisingEdge(dut.clk)
    cnt = [0] * n
    log = []
    ovf = False
    status = 0
    for burst in range(60):
        k = rng.randrange(1, P["EVQ"] + 3)                        # sometimes more than the log holds
        for _ in range(k):
            await FallingEdge(dut.clk)
            eof = rng.getrandbits(n) or 1
            dut.top_eof_i.value = eof
            await FallingEdge(dut.clk)
            dut.top_eof_i.value = 0
            for c in range(n):                                    # the model of the visible results
                if eof >> c & 1:
                    cnt[c] = (cnt[c] + 1) & 0xFFFFFFFF
                    if len(log) < P["EVQ"]:
                        log.append((c, cnt[c] & 0xFFFFFF))
                    else:
                        ovf = True
            status |= eof
            for _ in range(n + 1):                                # every pending event queued
                await FallingEdge(dut.clk)
        await Timer(1, unit="ns")
        assert int(dut.top_irq_o.value) == status, f"burst {burst}: irq_o {dut.top_irq_o.value} model {status:b}"
        for c in range(n):
            d, _ = await axi.read(A["COUNT"] + 4 * c)
            assert d == cnt[c], f"burst {burst}: COUNT[{c}] rtl {d} model {cnt[c]}"
        d, _ = await axi.read(A["STATUS"])
        assert d == status
        last_t = -1
        for _ in range(rng.randrange(0, len(log) + 2)):           # read and pop some events
            ev, _ = await axi.read(A["EVENT"])
            t, _ = await axi.read(A["EVENT_TIME"])
            exp = ((1 << 31) | (int(ovf) << 30) | (log[0][0] << 24) | log[0][1]) if log else int(ovf) << 30
            assert ev == exp, f"burst {burst}: EVENT rtl {ev:#x} model {exp:#x}"
            if log:
                assert t >= last_t, "EVENT_TIME not in order"
                last_t = t
                log.pop(0)
                cov["popped"] += 1
            await axi.write(A["EVENT_POP"], 1)
        cov["overflow"] += int(ovf)
        if ovf and rng.random() < 0.5:
            await axi.write(A["EVENT_POP"], 2)
            ovf = False
        clr = rng.getrandbits(n)
        await axi.write(A["STATUS"], clr)
        status &= ~clr
        if rng.random() < 0.3:
            c = rng.getrandbits(n)
            await axi.write(A["CLEAR"], c)
            cnt = [0 if c >> i & 1 else v for i, v in enumerate(cnt)]
    dut._log.info("%s register map: coverage %s", CASE, dict(cov))
    assert cov["popped"] and cov["overflow"]
