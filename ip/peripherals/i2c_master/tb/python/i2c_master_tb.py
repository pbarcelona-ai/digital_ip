"""cocotb tests of i2c_master against its golden model (ip/peripherals/i2c_master/model/i2c_master_model.py).

test_core_clock_exact: the logic (u_core of i2c_master_cocotb_top) with its register interface and streams
driven directly and a bit-level I2C target on the bus (Target: START / STOP detection, address match,
ACK, write bytes, read bytes MSB first, the master's ACK / NACK; it serves the same kind of device the model
talks to). Random transactions (write, read, address probe, unknown address, NO_STOP, DIV 0-20), TX bytes
pushed before and during them (the sequencer waits for them), RX tready random (the FIFO fills), aborts
(EN cleared during a wait), STATUS clears, IRQ_EN, a START while busy. Every clock, STATUS (BUSY, DONE,
NACK, ARB_LOST, RX_LEVEL), CTRL, irq_o, TX tready and the RX stream (tvalid, tdata, tlast) are compared
with the model's for the same clock; register writes act on the model in the clock the RTL sees their
pulse. At the end the target's devices and the model's must hold the same bytes.
test_register_map: the block (u_top) over AXI4-Lite against the model's register map (reset values, random
writes and reads, START to an absent target: NACK), compared when both are idle.
test_scl_timing: the block's SCL with DIV at its reset value: every low and high time of a transaction at
or above the UM10204 minimum of the bus mode (tLOW 4.7 / 1.3 / 0.5 us, tHIGH 4.0 / 0.6 / 0.26 us), the
period at or above 1 / SCL_HZ, DIV's reset value equal to the model's (div_reset).
Environment: I2C_CASE (parameter set), I2C_CYCLES (default 60000), I2C_SEED.
"""
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

model_path(IP / "model", IP.parents[1] / "shared" / "model")
import i2c_master_model as im                                     # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"fifo16": dict(CLK_HZ=100_000_000, SCL_HZ=100_000, FIFO_DEPTH=16),
         "soc": dict(CLK_HZ=200_000_000, SCL_HZ=400_000, FIFO_DEPTH=2),      # py_soc: IP_FIFO 2
         "deep": dict(CLK_HZ=100_000_000, SCL_HZ=100_000, FIFO_DEPTH=512)}
CASE = os.environ.get("I2C_CASE", "fifo16")
CFG = CASES[CASE]
CYCLES = int(os.environ.get("I2C_CYCLES", "60000"))
TRACE_FROM = int(os.environ.get("I2C_TRACE_FROM", "-1"))           # print every clock from this one (debug)
SEED = int(os.environ.get("I2C_SEED", "20261020"))
ADDRS = (0x36, 0x50)                                              # the devices on the bus
COV = collections.Counter()


class Mem:
    """An I2C memory device (EEPROM-like): a write's first byte sets the pointer, the rest are stored;
    reads return bytes from the pointer, which advances."""

    def __init__(self, seed):
        self.mem = bytearray(random.Random(seed).randbytes(256))
        self.ptr = 0

    def write(self, data):
        if data:
            self.ptr = data[0]
            for d in data[1:]:
                self.mem[self.ptr] = d & 0xFF
                self.ptr = (self.ptr + 1) & 0xFF

    def read(self, n):
        out = [self.mem[(self.ptr + k) & 0xFF] for k in range(n)]
        self.ptr = (self.ptr + n) & 0xFF
        return out


class Target:
    """Bit-level I2C target on the wrapper's bus lines (sampled every clock), never stretching SCL."""

    def __init__(self, devices):
        self.dev = devices
        self.scl = self.sda = 1
        self.state, self.drive = "idle", 0
        self.bits = self.shift = 0
        self.rw, self.cur, self.wbytes = 0, None, []

    def _flush(self):
        if self.cur is not None and self.wbytes:
            self.cur.write(self.wbytes)
        self.wbytes, self.cur = [], None

    def clock(self, scl, sda):
        """Lines of this clock -> the target's SDA pull (1: low)."""
        if scl and self.scl and self.sda and not sda:             # START (also repeated)
            self._flush()
            self.state, self.bits, self.shift, self.drive = "addr", 0, 0, 0
            COV["start"] += 1
        elif scl and self.scl and not self.sda and sda:           # STOP
            self._flush()
            self.state, self.drive = "idle", 0
        elif scl and not self.scl:                                # SCL rises: sample
            if self.state in ("addr", "wdata"):
                self.shift = (self.shift << 1) | sda
                self.bits += 1
            elif self.state == "rdata":
                self.bits += 1
            elif self.state == "mack":
                self.ack = sda == 0
        elif not scl and self.scl:                                # SCL falls: the next bit
            if self.state in ("addr", "wdata") and self.bits == 8:
                if self.state == "addr":
                    self.rw = self.shift & 1
                    self.cur = self.dev.get(self.shift >> 1)
                    self.state = "ack_addr" if self.cur is not None else "nack"
                else:
                    self.wbytes.append(self.shift & 0xFF)
                    self.state = "ack_data"
                self.drive = int(self.state != "nack")
            elif self.state == "nack":
                self.drive, self.state = 0, "idle"
            elif self.state == "ack_data":
                self.state, self.bits, self.shift, self.drive = "wdata", 0, 0, 0
            elif self.state in ("ack_addr", "mack"):
                if self.state == "ack_addr" and not self.rw:
                    self.state, self.bits, self.shift, self.drive = "wdata", 0, 0, 0
                elif self.state == "mack" and not self.ack:
                    self.state, self.drive = "idle", 0                # NACK: no more bytes
                else:
                    self.byte = self.cur.read(1)[0]
                    self.state, self.bits = "rdata", 0
                    self.drive = int(not (self.byte >> 7) & 1)
            elif self.state == "rdata":
                if self.bits == 8:
                    self.state, self.drive = "mack", 0
                else:
                    self.drive = int(not (self.byte >> (7 - self.bits)) & 1)
        self.scl, self.sda = scl, sda
        return self.drive


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_ctrl", "core_ctrl_wr", "core_addr", "core_len", "core_status", "core_status_wr",
              "core_irq_en", "tx_tdata", "tx_tvalid", "rx_tready", "tgt_scl_low", "tgt_sda_low"):
        getattr(dut, n).value = 0
    dut.core_div.value = 0
    for _ in range(4):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic and a bit-level target, clock for clock against the model."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    sim = Sim(CFG["CLK_HZ"])
    m_dev = {a: Mem(a) for a in ADDRS}
    t_dev = {a: Mem(a) for a in ADDRS}
    m = im.I2cMaster(sim, lambda: None, m_dev, CFG["CLK_HZ"], CFG["SCL_HZ"], CFG["FIFO_DEPTH"])
    tgt = Target(t_dev)
    regs = dict(ADDR=0, LEN=0, DIV=0, IRQ_EN=0)
    for k, v in regs.items():
        m.r.set(k, v)
    gap, tx_left, rx_ready_p, en = 20, 0, 0.8, 1
    push_p, hold = 0.3, 0                                     # TX push probability; RX tready held low until
    directed = CFG["FIFO_DEPTH"] <= 64                        # first: a read longer than the RX FIFO, not taken
    hist = collections.deque(maxlen=12)                         # recent clocks, for a failure report
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        sim.advance(1)                                            # the model in clock cyc
        # the target sees this clock's lines
        scl, sda = int(dut.scl_line.value), int(dut.sda_line.value)
        dut.tgt_sda_low.value = tgt.clock(scl, sda)
        if 0 <= TRACE_FROM <= cyc:
            dut._log.info("clock %d scl %d sda %d target %s drive %d fsm %d", cyc, scl, sda, tgt.state, tgt.drive,
                          int(dut.u_core.u_fsm.state.value))
        # stimulus of this clock
        ctrl_wr = status_wr = 0
        ctrl = status = 0
        idle = not m.busy and not m.active
        if idle and gap > 0:
            gap -= 1
        elif idle and gap == 0:                                   # a new transaction
            regs["ADDR"] = rng.choice(ADDRS + (0x11,)) if rng.random() < 0.95 else rng.getrandbits(7)
            regs["LEN"] = rng.choice((0, 1, 2, 3, 5, 8, 20 if CFG["FIFO_DEPTH"] == 16 else 6))
            regs["DIV"] = rng.choice((0, 1, 2, 3, 7, 20))
            rd = rng.random() < 0.45 and regs["LEN"] > 0     # a read takes a byte (I2C: an address probe writes)
            if directed:
                regs["ADDR"], regs["LEN"], regs["DIV"], rd, directed = 0x50, CFG["FIFO_DEPTH"] + 4, 0, True, False
            en = 1
            ctrl, ctrl_wr = 1 | 2 | (4 if rd else 0) | (8 if rng.random() < 0.2 else 0), 1
            m.txf.sync(cyc + 1)                                   # top up to the bytes needed (+-1)
            tx_left = 0 if rd else max(0, regs["LEN"] - m.txf.level() + rng.choice((0, 0, 0, -1, 1)))
            rx_ready_p = rng.choice((0.9, 0.5, 0.05))
            hold = cyc + rng.choice((0, 0, 3000))                 # sometimes no RX taken for a while (full)
            if rd and regs["LEN"] > CFG["FIFO_DEPTH"]:
                hold = cyc + 50 * (regs["DIV"] + 2) * regs["LEN"]  # a long read: the RX FIFO fills
            push_p = rng.choice((0.3, 0.3, 0.002))                # sometimes TX bytes come slowly (waits)
            gap = rng.randint(0, 60)
            COV["read" if rd else "write"] += 1
        elif not idle and cyc >= hold and rng.random() < 0.0015:   # abort (EN low) or a START while busy
            if rng.random() < 0.5:
                ctrl, ctrl_wr, en = 0, 1, 0
                COV["abort"] += 1
            else:
                ctrl, ctrl_wr = 1 | 2, 1
                COV["start_busy"] += 1
        if rng.random() < 0.01:                                   # clear flags / toggle the interrupt
            status, status_wr = rng.getrandbits(4) << 1 & 0xE, 1
        if rng.random() < 0.003:
            regs["IRQ_EN"] ^= 1
        tx_ready = int(dut.tx_tready.value)
        push = tx_left > 0 and tx_ready and rng.random() < push_p
        byte = rng.getrandbits(8)
        rx_ready = int(cyc >= hold and rng.random() < rx_ready_p)
        dut.core_addr.value, dut.core_len.value = regs["ADDR"], regs["LEN"]
        dut.core_div.value, dut.core_irq_en.value = regs["DIV"], regs["IRQ_EN"]
        dut.core_ctrl.value, dut.core_ctrl_wr.value = ctrl, ctrl_wr
        dut.core_status.value, dut.core_status_wr.value = status, status_wr
        dut.tx_tdata.value, dut.tx_tvalid.value = byte, int(push)
        dut.rx_tready.value = rx_ready
        await Timer(1, unit="ns")
        # compare this clock
        for k, v in regs.items():
            m.r.set(k, v)
        r = dict(status=int(dut.core_sts_status.value), ctrl=int(dut.core_sts_ctrl.value),
                 irq=int(dut.core_irq_o.value), tx_ready=tx_ready, rx_valid=int(dut.rx_tvalid.value))
        m.rxf.sync(cyc + 1)
        mo = dict(status=m.r.sts("STATUS", 0), ctrl=m.r.sts("CTRL", 0), irq=int(m.irq()),
                  tx_ready=int(not (m.txf.sync(cyc + 1) or m.txf.full())), rx_valid=int(m.rxf.tvalid()))
        if r["rx_valid"]:
            r["rx"] = (int(dut.rx_tdata.value), int(dut.rx_tlast.value))
            mo["rx"] = (m.rxf.o_q[0], m.rxf.o_q[1]) if m.rxf.o_q else None
        hist.append((cyc, ctrl_wr and ctrl, status_wr and status, push, rx_ready, int(dut.u_core.u_fsm.state.value),
                     r["status"], mo["status"], m.wait_kind))
        assert r == mo, f"clock {cyc}: rtl {r} model {mo}; recent (clock, ctrl, status, push, rx_ready, " \
                        f"fsm, rtl status, model status, wait): {list(hist)}"
        # this clock's inputs to the model
        if ctrl_wr:
            m._w("CTRL", 0, ctrl)
        if status_wr:
            m._w("STATUS", 0, status)
        if push:
            assert m.push_tx(cyc + 1, byte)
            tx_left -= 1
        if rx_ready and r["rx_valid"]:
            m.take_rx(cyc + 1)
            COV["rx_byte"] += 1
        COV["rx_full"] += m.rxf.full()
        COV["nack"] += (r["status"] >> 2) & 1
        COV["irq"] += r["irq"]
        COV["tx_wait"] += m.wait_kind == "tx"
    assert m_dev.keys() == t_dev.keys() and all(m_dev[a].mem == t_dev[a].mem for a in ADDRS), "device contents"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(COV))
    for k in ("read", "write", "abort", "rx_byte", "nack", "irq", "tx_wait", "start_busy"):
        assert COV[k], f"not covered: {k}"
    if CFG["FIFO_DEPTH"] == 16:
        assert COV["rx_full"], "not covered: rx FIFO full"


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map, compared whenever both are idle."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    sim = Sim(CFG["CLK_HZ"])
    m = im.I2cMaster(sim, lambda: None, {}, CFG["CLK_HZ"], CFG["SCL_HZ"], CFG["FIFO_DEPTH"])   # no target

    async def follow():                                           # the model's time follows the clock
        while True:
            await RisingEdge(dut.aclk)
            sim.advance(1)
    cocotb.start_soon(follow())

    async def settle():
        for _ in range(4):
            await RisingEdge(dut.aclk)
        while m.busy or m.active:
            await RisingEdge(dut.aclk)
        for _ in range(4):
            await RisingEdge(dut.aclk)

    offs = sorted(m.r.regs) + [0x0, 0x4, 0x8, 0xC, 0x28, 0x40, 0xFC]
    for off in sorted(set(offs)):                                # reset values
        d, resp = await axi.read(off)
        assert (d, resp) == m.r.read(off), f"reset 0x{off:02X}: rtl {d:x}/{resp} model {m.r.read(off)}"
    for k in range(400):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if off == 0x1C:
                d &= 0xF                                          # short phases: transactions end quickly
            if off == 0x10 and rng.random() < 0.7:
                d &= ~2                                           # mostly no START
            resp = await axi.write(off, d)
            mresp = m.r.write(off, d)
            assert resp == mresp, f"write 0x{off:02X} = {d:x}: rtl resp {resp} model {mresp}"
            COV["reg_start"] += off == 0x10 and d & 3 == 3
            await settle()
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    assert COV["reg_start"], "no START through the register map"
    dut._log.info("register map: 400 accesses compared")


@cocotb.test()
async def test_scl_timing(dut):
    """SCL low / high times at the reset DIV against UM10204 Table 10."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    axi = AxilMaster(dut, dut.aclk)
    clk, scl = CFG["CLK_HZ"], CFG["SCL_HZ"]
    div, _ = await axi.read(0x1C)
    assert div == im.div_reset(clk, scl), f"DIV reset {div} model {im.div_reset(clk, scl)}"
    tlow, thigh = (4.7e-6, 4.0e-6) if scl <= 100_000 else (1.3e-6, 0.6e-6) if scl <= 400_000 else (0.5e-6, 0.26e-6)
    await axi.write(0x14, 0x11)                                   # no target: address NACK, STOP
    await axi.write(0x18, 0)
    await axi.write(0x10, 3)
    runs, level, n, last_rise = [], 1, 0, None
    periods = []
    for _ in range(40 * 4 * (div + 2) * 2):
        await RisingEdge(dut.aclk)
        v = int(dut.top_scl.value)
        if v != level:
            runs.append((level, n))
            if v:
                if last_rise is not None:
                    periods.append(last_rise)
                last_rise = 0
            level, n = v, 0
        n += 1
        if last_rise is not None:
            last_rise += 1
    lows = [k for lv, k in runs if lv == 0]
    highs = [k for lv, k in runs[1:] if lv == 1]                  # not the idle level before the START
    assert lows and highs, "no SCL activity"
    assert min(lows) >= tlow * clk, f"tLOW {min(lows)} clocks < {tlow * clk:.0f}"
    assert min(highs) >= thigh * clk, f"tHIGH {min(highs)} clocks < {thigh * clk:.0f}"
    assert min(periods) >= clk / scl, f"SCL period {min(periods)} clocks < {clk / scl:.0f}"
    dut._log.info("SCL: tLOW >= %.3f us, tHIGH >= %.3f us, f <= %.1f kHz", min(lows) / clk * 1e6,
                  min(highs) / clk * 1e6, clk / min(periods) / 1e3)
