"""cocotb tests of py_stream_port against its golden model (ip/cpu/py_soc/model/py_stream_port_model.py).

test_core_clock_exact: the logic (u_core) with its register interface and streams driven directly, clock
for clock: random TXDATA writes (overflow when full, TX_OVF clears), RXDATA reads (the read pulse in the
clock the word is returned pops it), the peripheral taking TX words and offering RX words at random rates,
IRQ_EN. Every clock RXDATA, STATUS, the TX stream (tvalid, data, last) and the RX stream's tready equal the
model's; irq_o equals the model's condition of the clock before (registered).
test_register_map: the block (u_top: TX not taken, no RX) over AXI4-Lite against the model's register map.
Environment: PORT_CASE, PORT_CYCLES (default 30000), PORT_SEED.
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
from event_sim import Sim                                         # noqa: E402
from py_stream_port_model import StreamPort                       # noqa: E402

CASES = {"soc": dict(DATA_W=8, TX_DEPTH=16, RX_DEPTH=16), "spi": dict(DATA_W=16, TX_DEPTH=4, RX_DEPTH=2)}
CASE = os.environ.get("PORT_CASE", "soc")
CFG = CASES[CASE]
CYCLES = int(os.environ.get("PORT_CYCLES", "30000"))
SEED = int(os.environ.get("PORT_SEED", "20261020"))


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_txdata", "core_txdata_wr", "core_rxdata_rd", "core_status", "core_status_wr", "core_irq_en",
              "ptx_tready", "prx_tdata", "prx_tlast", "prx_tvalid"):
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
    sim = Sim()
    p = StreamPort(sim, CFG["TX_DEPTH"], CFG["RX_DEPTH"], CFG["DATA_W"])
    cov = collections.Counter()
    irq_en, prev_irq = 0, 0
    rates = (0.3, 0.3, 0.3, 0.3)                                  # TX write, RX read, peripheral take, offer
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        sim.advance(1)
        if rng.random() < 0.01:
            rates = tuple(rng.choice((0.0, 0.05, 0.3, 0.9)) for _ in range(4))
        if rng.random() < 0.003:
            irq_en = rng.getrandbits(3)
        txw = rng.random() < rates[0]
        rdp = rng.random() < rates[1]
        stw = not txw and rng.random() < 0.01
        take = int(rng.random() < rates[2])
        offer = int(rng.random() < rates[3])
        txd = rng.getrandbits(25)
        rxw = (rng.getrandbits(CFG["DATA_W"]), rng.getrandbits(1))
        dut.core_txdata.value, dut.core_txdata_wr.value = txd, int(txw)
        dut.core_rxdata_rd.value = int(rdp)
        dut.core_status.value, dut.core_status_wr.value = 4 if stw else 0, int(stw)
        dut.core_irq_en.value = irq_en
        dut.ptx_tready.value = take
        dut.prx_tdata.value, dut.prx_tlast.value, dut.prx_tvalid.value = rxw[0], rxw[1], offer
        await Timer(1, unit="ns")
        p.r.set("IRQ_EN", irq_en)
        p.txf.sync(sim.now)
        r = dict(rx=int(dut.core_sts_rxdata.value), st=int(dut.core_sts_status.value),
                 tv=int(dut.ptx_tvalid.value), rr=int(dut.prx_tready.value), irq=int(dut.core_irq_o.value))
        mo = dict(rx=p.r.sts("RXDATA", 0), st=p.r.sts("STATUS", 0), tv=int(p.txf.tvalid()),
                  rr=int(not (p.rxf.sync(sim.now) or p.rxf.full())), irq=prev_irq)
        if r["tv"]:
            r["tx"] = (int(dut.ptx_tdata.value), int(dut.ptx_tlast.value))
            mo["tx"] = (p.txf.o_q[0], p.txf.o_q[1])
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}"
        prev_irq = int(p.irq())
        # this clock's handshakes on the model
        if txw:
            p.r.write(0x10, txd)
            cov["ovf"] += p.tx_ovf
        if rdp:
            p.r.read(0x14)                                        # RC: returns and pops (the read pulse)
        if stw:
            p.r.write(0x18, 4)
        if take and r["tv"]:
            p.take_tx(sim.now)
            cov["tx"] += 1
        if offer and r["rr"]:
            assert p.push_rx(sim.now, *rxw)
            cov["rx"] += 1
        cov["rx_full"] += not r["rr"]
        cov["irq"] += r["irq"]
    assert all(cov[k] for k in ("ovf", "tx", "rx", "rx_full", "irq")), f"coverage {dict(cov)}"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(cov))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map (TX words kept, no RX)."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    sim = Sim()
    p = StreamPort(sim, CFG["TX_DEPTH"], CFG["RX_DEPTH"], CFG["DATA_W"])
    offs = sorted(set(p.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x20, 0xFC})
    for k in range(500):
        off = rng.choice(offs)
        sim.now += 10                                             # the FIFO pipeline has settled between accesses
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            assert await axi.write(off, d) == p.r.write(off, d), f"write 0x{off:02X}"
        else:
            d, resp = await axi.read(off)
            md = p.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):                                            # the last writes applied before the end
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 500 accesses compared")
