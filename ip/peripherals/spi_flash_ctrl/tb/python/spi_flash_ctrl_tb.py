"""cocotb tests of spi_flash_ctrl against its golden model
(ip/peripherals/spi_flash_ctrl/model/spi_flash_ctrl_model.py).

test_core_clock_exact: the logic (u_core) with its register interface, streams and MISO driven directly, clock
for clock: random commands (opcode, with / without address, 0-3 dummy bytes, LEN 0-6, read, write, both,
neither), CLKDIV 0-6 (below 3 acts as 3), MISO random per clock, write bytes and read tready at random rates
(the controller waits for both), CMD writes while busy (CMD_ERR), STATUS clears, IRQ_EN. Every clock STATUS,
irq_o, SCLK, MOSI, CS_N, TX tready and the read stream (tvalid, tdata, tlast) equal the model's.
test_register_map: the block (u_top) over AXI4-Lite against the model's register map.
Environment: FLASH_CYCLES (default 80000), FLASH_SEED.
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
import spi_flash_ctrl_model as fm                                 # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"one": {}}
CYCLES = int(os.environ.get("FLASH_CYCLES", "80000"))
SEED = int(os.environ.get("FLASH_SEED", "20261020"))


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_cmd", "core_cmd_wr", "core_addr", "core_len", "core_status", "core_status_wr", "core_irq_en",
              "tx_tdata", "tx_tvalid", "rx_tready", "miso_i"):
        getattr(dut, n).value = 0
    dut.core_clkdiv.value = 4
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic and its pins, clock for clock against the model."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    sim = Sim()
    m = fm.FlashCore(sim, lambda: None)
    wave = {}
    m.miso_source = lambda n: wave.get(n, 0)
    cov = collections.Counter()
    regs = dict(ADDR=0, LEN=0, CLKDIV=4, IRQ_EN=0)
    push_p, take_p = 0.3, 0.5
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        sim.advance(1)
        t = sim.now
        cmd_wr = st_wr = 0
        cmd = 0
        idle = t >= m.idle_from
        if (idle and rng.random() < 0.02) or (not idle and rng.random() < 0.0005):
            regs["ADDR"] = rng.getrandbits(24)
            regs["LEN"] = rng.choice((0, 1, 2, 3, 6))
            if idle:                                              # CLKDIV only between commands
                regs["CLKDIV"] = rng.choice((0, 2, 3, 4, 6))
            rd, wr = rng.getrandbits(1), rng.getrandbits(1)
            cmd = rng.getrandbits(8) | rng.getrandbits(1) << 8 | rng.randint(0, 3) << 12 | rd << 16 | wr << 17
            cmd_wr = 1
            push_p, take_p = rng.choice((0.02, 0.3, 1.0)), rng.choice((0.02, 0.3, 1.0))
            cov["cmd" if idle else "cmd_busy"] += 1
            cov[f"rd{rd}wr{wr}"] += idle
        if rng.random() < 0.003:
            st_wr = 1
        if rng.random() < 0.002:
            regs["IRQ_EN"] ^= 1
        miso = rng.getrandbits(1)
        wave[t] = miso
        tx_ready = int(dut.tx_tready.value)
        push = int(rng.random() < push_p)
        byte = rng.getrandbits(8)
        take = int(rng.random() < take_p)
        dut.core_cmd.value, dut.core_cmd_wr.value = cmd, cmd_wr
        dut.core_addr.value, dut.core_len.value = regs["ADDR"], regs["LEN"]
        dut.core_clkdiv.value, dut.core_irq_en.value = regs["CLKDIV"], regs["IRQ_EN"]
        dut.core_status.value, dut.core_status_wr.value = 6 if st_wr else 0, st_wr
        dut.tx_tdata.value, dut.tx_tvalid.value = byte, push
        dut.rx_tready.value = take
        dut.miso_i.value = miso
        await Timer(1, unit="ns")
        for k, v in regs.items():
            m.r.set(k, v)
        r = dict(st=int(dut.core_sts_status.value), irq=int(dut.core_irq_o.value), sclk=int(dut.sclk_o.value),
                 mosi=int(dut.mosi_o.value), cs=int(dut.cs_n_o.value), tr=tx_ready, rv=int(dut.rx_tvalid.value))
        mo = dict(st=m.r.sts("STATUS", 0), irq=int(m.irq()), sclk=m.sclk.at(t), mosi=m.mosi.at(t), cs=m.cs_n.at(t),
                  tr=int(m.wtx is not None and t >= m.wtx[0]), rv=int(m.out.tvalid(t)))
        if r["rv"]:
            r["rx"] = (int(dut.rx_tdata.value), int(dut.rx_tlast.value))
            mo["rx"] = (m.out.word[0], m.out.word[1])
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        if cmd_wr:
            m.r.set("CMD", cmd)
            m._w("CMD", 0, cmd)
        if st_wr:
            m._w("STATUS", 0, 6)
        if push and tx_ready:
            assert m.push_tx(t, byte)
            cov["tx"] += 1
        if take and r["rv"]:
            m.take_rx(t)
            cov["rx"] += 1
        cov["err"] += (r["st"] >> 2) & 1
        cov["irq"] += r["irq"]
    for k in ("cmd", "cmd_busy", "tx", "rx", "err", "irq", "rd1wr0", "rd0wr1", "rd1wr1", "rd0wr0"):
        assert cov[k], f"not covered: {k} ({dict(cov)})"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(cov))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map (no commands started)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    m = fm.FlashCore(Sim(), lambda: None)
    offs = sorted(set(m.r.regs) - {0x10} | {0x0, 0x4, 0x8, 0xC, 0x28, 0xFC})
    for k in range(500):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:02X}"
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 500 accesses compared")
