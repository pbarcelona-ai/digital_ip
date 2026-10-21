"""cocotb tests of spi_master against its golden model (ip/peripherals/spi_master/model/spi_master_model.py).

test_core_clock_exact: the logic (u_core) with its register interface, streams and MISO driven directly, clock
for clock: bursts of words (tlast ends a chip-select burst), every SPI mode (CPOL, CPHA), MSB / LSB first,
word lengths 1..DATA_W and out-of-range values, DIV 0..9 (below 2 acts as 2), both chip selects (and an
out-of-range one), MISO either random per clock or MOSI looped back (the board), TX words and RX tready at
random rates (overrun), STATUS clears; settings change only between bursts (the model's documented
assumption). Every clock STATUS, SCLK, MOSI, CS_N, TX tready and the RX stream (tvalid, tdata, tlast) equal
the model's.
test_register_map: the block (u_top) over AXI4-Lite against the model's register map.
Environment: SPI_CASE, SPI_CYCLES (default 80000), SPI_SEED.
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

model_path(IP / "model", IP.parents[1] / "shared" / "model")
import spi_master_model as sm                                     # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"soc": dict(CLK_HZ=200_000_000, SCLK_HZ=10_000_000, DATA_W=16, NUM_CS=2, FIFO_DEPTH=2),
         "wide": dict(CLK_HZ=100_000_000, SCLK_HZ=10_000_000, DATA_W=24, NUM_CS=4, FIFO_DEPTH=4)}
CASE = os.environ.get("SPI_CASE", "soc")
CFG = CASES[CASE]
CYCLES = int(os.environ.get("SPI_CYCLES", "80000"))
SEED = int(os.environ.get("SPI_SEED", "20261020"))


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_ctrl", "core_status", "core_status_wr", "tx_tdata", "tx_tlast", "tx_tvalid", "rx_tready",
              "miso_i", "board_loop"):
        getattr(dut, n).value = 0
    dut.core_div.value = CFG["CLK_HZ"] // (2 * CFG["SCLK_HZ"]) - 1
    dut.core_word_len.value = 8
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic and its pins, clock for clock against the model."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    sim = Sim(CFG["CLK_HZ"])
    m = sm.SpiCore(sim, lambda: None, CFG["CLK_HZ"], CFG["SCLK_HZ"], CFG["DATA_W"], CFG["NUM_CS"], CFG["FIFO_DEPTH"])
    cov = collections.Counter()
    wave = {}
    regs = dict(CTRL=0, DIV=m.r.get("DIV"), WORD_LEN=8)
    loop, push_p, take_p, burst = 0, 0.2, 0.5, 0
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        sim.advance(1)
        t = sim.now
        m.txf.sync(t)
        quiet = not m.active and not m.cs_active and m.txf.level() == 0
        if quiet and rng.random() < 0.01:                         # new settings between bursts
            regs["CTRL"] = (1 | rng.getrandbits(3) << 1 | rng.choice((0, 0, 1, CFG["NUM_CS"])) << 8)
            regs["DIV"] = rng.choice((0, 1, 2, 3, 5, 9))
            regs["WORD_LEN"] = rng.choice((1, 3, 8, CFG["DATA_W"], 0, CFG["DATA_W"] + 1, 63))
            loop = rng.getrandbits(1)
            push_p, take_p = rng.choice((0.02, 0.2, 0.8)), rng.choice((0.0, 0.1, 0.6, 1.0))
            burst = rng.randint(1, 5)
            cov[f"mode{(regs['CTRL'] >> 1) & 3}"] += 1
            cov["loop" if loop else "random_miso"] += 1
        miso = rng.getrandbits(1)
        wave[t] = miso
        st_wr = int(rng.random() < 0.003)
        tx_ready = int(dut.tx_tready.value)
        push = tx_ready and burst and rng.random() < push_p
        word = rng.getrandbits(CFG["DATA_W"])
        tlast = int(push and (burst == 1 or rng.random() < 0.2))
        take = int(rng.random() < take_p)
        dut.core_ctrl.value, dut.core_div.value, dut.core_word_len.value = regs["CTRL"], regs["DIV"], regs["WORD_LEN"]
        dut.core_status.value, dut.core_status_wr.value = 2 if st_wr else 0, st_wr
        dut.tx_tdata.value, dut.tx_tlast.value, dut.tx_tvalid.value = word, tlast, int(push)
        dut.rx_tready.value = take
        dut.miso_i.value, dut.board_loop.value = miso, loop
        await Timer(1, unit="ns")
        for k, v in regs.items():
            if k == "CTRL" and m.r.get(k) != v:
                m.r.set(k, v)
                m._w("CTRL", 0, v)                                # idle SCLK / CS_N follow the next clock
            m.r.set(k, v)
        m.miso_source = None if loop else (lambda n: wave.get(n, 0))
        m.rxf.sync(t)
        r = dict(st=int(dut.core_sts_status.value), sclk=int(dut.sclk_o.value), mosi=int(dut.mosi_o.value),
                 cs=int(dut.cs_n_o.value), tr=tx_ready, rv=int(dut.rx_tvalid.value))
        mo = dict(st=m.r.sts("STATUS", 0), sclk=m.sclk.at(t), mosi=m.mosi.at(t), cs=m.cs_n.at(t),
                  tr=int(not m.txf.full()), rv=int(m.rxf.tvalid()))
        if r["rv"]:
            r["rx"] = (int(dut.rx_tdata.value), int(dut.rx_tlast.value))
            mo["rx"] = (m.rxf.o_q[0], m.rxf.o_q[1])
        assert r == mo, f"clock {cyc} (ctrl {regs['CTRL']:#x} div {regs['DIV']} wl {regs['WORD_LEN']}): rtl {r} model {mo}"
        if st_wr:
            m._w("STATUS", 0, 2)
        if push:
            assert m.push_tx(t, word, tlast)
            cov["tx"] += 1
            burst -= tlast
        if take and r["rv"]:
            m.take_rx(t)
            cov["rx"] += 1
        cov["ovr"] += (r["st"] >> 1) & 1
    for k in ("tx", "rx", "ovr", "mode0", "mode1", "mode2", "mode3", "loop", "random_miso"):
        assert cov[k], f"not covered: {k} ({dict(cov)})"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(cov))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    sim = Sim(CFG["CLK_HZ"])
    m = sm.SpiCore(sim, lambda: None, CFG["CLK_HZ"], CFG["SCLK_HZ"], CFG["DATA_W"], CFG["NUM_CS"], CFG["FIFO_DEPTH"])
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x20, 0xFC})
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
