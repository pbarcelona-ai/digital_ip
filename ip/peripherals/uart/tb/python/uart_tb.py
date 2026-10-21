"""cocotb tests of uart against its golden model (ip/peripherals/uart/model/uart_model.py).

test_core_clock_exact: the logic (u_core) with its register interface, streams and RX line driven directly,
clock for clock, in phases: internal loopback (CTRL[5]), the board loopback (TXD wired to RXD), and an
external line from the testbench (Line: random frames at the baud rate of the moment, with parity or stop-bit
errors, glitches shorter than half a bit, breaks); line settings (data bits 5-8, parity even / odd, 1 / 2 stop
bits) changed between frames; FCW changed during frames; TX bytes and RX tready at random rates; STATUS
clears. Every clock STATUS, ERR_CNT, TXD, TX tready and the RX stream (tvalid, tdata) equal the model's.
test_register_map: the block (u_top) over AXI4-Lite against the model's register map (reset values and random
accesses; STATUS / ERR_CNT with the engines idle).
Environment: UART_CASE, UART_CYCLES (default 150000), UART_SEED.
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
import uart_model as um                                           # noqa: E402
from event_sim import Sim                                         # noqa: E402

CASES = {"fast": dict(CLK_HZ=100_000_000, BAUD=1_000_000, FIFO_DEPTH=4),
         "soc": dict(CLK_HZ=200_000_000, BAUD=2_000_000, FIFO_DEPTH=2)}
CASE = os.environ.get("UART_CASE", "fast")
CFG = CASES[CASE]
CYCLES = int(os.environ.get("UART_CYCLES", "150000"))
SEED = int(os.environ.get("UART_SEED", "20261020"))
COV = collections.Counter()


class Line:
    """The testbench's serial source: frames at a given clocks-per-bit, with errors, glitches and breaks."""

    def __init__(self, rng):
        self.rng, self.q, self.level = rng, [], 1

    def queue_frame(self, cpb, bits, par, odd, stop2):
        r = self.rng
        byte = r.getrandbits(bits)
        data = [(byte >> k) & 1 for k in range(bits)]
        frame = [0] + data
        if par:
            p = 0
            for b in data:
                p ^= b
            p ^= odd
            if r.random() < 0.15:
                p ^= 1                                            # a parity error
                COV["parity_err"] += 1
            frame.append(p)
        stop = 1
        if r.random() < 0.1:
            stop = 0                                              # a framing error
            COV["frame_err"] += 1
        frame += [stop] + ([1] if stop2 else [])
        for b in frame:
            self.q += [b] * cpb
        self.q += [1] * r.randint(0, 3 * cpb)                     # idle between frames

    def queue_glitch(self, cpb):
        self.q += [0] * self.rng.randint(1, cpb // 3) + [1] * (2 * cpb)
        COV["glitch"] += 1

    def queue_break(self, cpb):
        self.q += [0] * (cpb * 14) + [1] * (2 * cpb)
        COV["break"] += 1

    def next(self):
        self.level = self.q.pop(0) if self.q else 1
        return self.level


async def reset(dut):
    dut.aresetn.value = 0
    for n in ("core_fcw_wr", "core_status", "core_status_wr", "tx_tdata", "tx_tvalid", "rx_tready", "board_loop"):
        getattr(dut, n).value = 0
    dut.core_ctrl.value = 3
    dut.core_fcw.value = um.fcw_of(CFG["CLK_HZ"], CFG["BAUD"])
    dut.rxd_i.value = 1
    for _ in range(3):
        await FallingEdge(dut.aclk)
    dut.aresetn.value = 1


@cocotb.test()
async def test_core_clock_exact(dut):
    """The logic and its RX line, clock for clock against the model."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED)
    sim = Sim(CFG["CLK_HZ"])
    m = um.UartCore(sim, lambda: None, CFG["CLK_HZ"], CFG["BAUD"], CFG["FIFO_DEPTH"])
    line = Line(rng)
    wave = {}                                                     # the external RX line per clock
    m.rxd_source = lambda n: wave.get(n, 1)
    ctrl, fcw = 3, m.r.get("FCW")
    mode, push_p, take_p = "ext", 0.02, 0.5
    prev_rxd = 1
    plan = ["ext", "loop", "board", "ext", "board", "loop", "ext", "ext"]   # a mode per eighth of the run
    want = mode
    for cyc in range(CYCLES):
        await FallingEdge(dut.aclk)
        sim.advance(1)
        t = sim.now
        idle = not (m.tx_active or m.rx_active) and m.txf.level() == 0 and not line.q
        if cyc % 4000 == 0:
            want = plan[cyc * len(plan) // CYCLES]
        if idle and (want != mode or rng.random() < 0.002):      # new mode / line settings between frames
            mode = want
            ctrl = 3 | rng.getrandbits(3) << 2 | rng.getrandbits(2) << 6
            ctrl = (ctrl & ~0x20) | (0x20 if mode == "loop" else 0)
            push_p, take_p = rng.choice((0.002, 0.02, 0.2)), rng.choice((0.0, 0.05, 0.5, 1.0))
            COV["mode_" + mode] += 1
        fcw_wr = 0
        if rng.random() < 0.0004:                                 # a new baud rate, in flight or not
            fcw = um.fcw_of(CFG["CLK_HZ"], int(CFG["BAUD"] * rng.choice((0.5, 0.75, 1.0, 1.1))))
            fcw_wr = 1
            COV["fcw"] += 1
        c = m.ctrl()
        cpb = max(4, (1 << 32) * 16 // max(1, fcw))               # clocks per bit at the present rate
        if mode == "ext" and want == mode and not line.q and rng.random() < 0.01:
            x = rng.random()
            if x < 0.85:
                line.queue_frame(cpb, c["bits"], c["par"], c["odd"], c["stop2"])
            elif x < 0.93:
                line.queue_glitch(cpb)
            else:
                line.queue_break(cpb)
        rxd = line.next() if mode == "ext" else 1
        wave[t] = rxd
        if rxd == 0 and prev_rxd == 1 and mode == "ext":
            m.rx_line_fell(t)
        prev_rxd = rxd
        st_wr = int(rng.random() < 0.002)
        tx_ready = int(dut.tx_tready.value)
        push = tx_ready and rng.random() < push_p and mode != "ext" and want == mode
        byte = rng.getrandbits(8)
        take = int(rng.random() < take_p)
        dut.core_ctrl.value, dut.core_fcw.value, dut.core_fcw_wr.value = ctrl, fcw, fcw_wr
        dut.core_status.value, dut.core_status_wr.value = 0x700 if st_wr else 0, st_wr
        dut.tx_tdata.value, dut.tx_tvalid.value = byte, int(push)
        dut.rx_tready.value = take
        dut.rxd_i.value, dut.board_loop.value = rxd, int(mode == "board")
        await Timer(1, unit="ns")
        m.r.set("CTRL", ctrl)
        m.rxd_source = (lambda n: wave.get(n, 1)) if mode == "ext" else None
        m.rxf.sync(t)
        m.txf.sync(t)
        r = dict(st=int(dut.core_sts_status.value), err=int(dut.core_sts_err_cnt.value), txd=int(dut.txd_o.value),
                 tr=tx_ready, rv=int(dut.rx_tvalid.value))
        mo = dict(st=m.r.sts("STATUS", 0), err=m.r.sts("ERR_CNT", 0), txd=m.txd_at(t), tr=int(not m.txf.full()),
                  rv=int(m.rxf.tvalid()))
        if r["rv"]:
            r["rx"] = int(dut.rx_tdata.value)
            mo["rx"] = m.rxf.o_q[0]
        assert r == mo, f"clock {cyc} (mode {mode}, ctrl {ctrl:#x}): rtl {r} model {mo}"
        if fcw_wr:
            m.r.set("FCW", fcw)
            m._w("FCW", 0, fcw)
        if st_wr:
            m._w("STATUS", 0, 0x700)
        if push:
            assert m.push_tx(t, byte)
            COV["tx"] += 1
        if take and r["rv"]:
            m.take_rx(t)
            COV["rx"] += 1
        COV["ovr"] += (r["st"] >> 10) & 1
    for k in ("tx", "rx", "ovr", "parity_err", "frame_err", "glitch", "break", "fcw", "mode_loop", "mode_board"):
        assert COV[k], f"not covered: {k} ({dict(COV)})"
    dut._log.info("core: %d clocks compared, %s", CYCLES, dict(COV))


@cocotb.test()
async def test_register_map(dut):
    """The block over AXI4-Lite against the model's register map."""
    cocotb.start_soon(Clock(dut.aclk, 10, unit="ns").start())
    await reset(dut)
    rng = random.Random(SEED + 1)
    axi = AxilMaster(dut, dut.aclk)
    sim = Sim(CFG["CLK_HZ"])
    m = um.UartCore(sim, lambda: None, CFG["CLK_HZ"], CFG["BAUD"], CFG["FIFO_DEPTH"])
    offs = sorted(set(m.r.regs) | {0x0, 0x4, 0x8, 0xC, 0x20, 0xFC})
    for k in range(500):
        off = rng.choice(offs)
        if rng.random() < 0.5:
            d = rng.getrandbits(32)
            if off == 0x10:
                d &= ~0x3                                         # engines off: no frames to time
            assert await axi.write(off, d) == m.r.write(off, d), f"write 0x{off:02X}"
        else:
            d, resp = await axi.read(off)
            md = m.r.read(off)
            assert (d, resp) == md, f"read 0x{off:02X}: rtl {d:x}/{resp} model {md[0]:x}/{md[1]}"
    for _ in range(2):
        await FallingEdge(dut.aclk)
    dut._log.info("register map: 500 accesses compared")
