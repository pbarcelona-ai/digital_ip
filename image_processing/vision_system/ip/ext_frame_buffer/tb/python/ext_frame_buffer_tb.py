"""cocotb test of ext_frame_buffer against its model (ip/ext_frame_buffer/model/ext_frame_buffer_model.py), clock
exact. A responder plays the SDRAM: ACTIVATE opens a row, WRITE stores the bus at (row, column), READ puts that
word on the bus from the next clock until the next command reads or writes. Random pixel writes (bursts that
fill the FIFO, addresses on a few rows so row hits, misses and precharges all occur) and four-address reads
(written and unwritten words), with refreshes due often; in every clock the command pins, wr_ready, wr_idle,
rd_ready, rd_valid, rd_data0..3 and, on a WRITE, the data on the bus equal the model, from reset through the
initialisation. Environment: EFB_N (clocks, default 30000), EFB_SEED."""
from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, Timer

import vs_cocotb

vs_cocotb.models()
import ext_frame_buffer_model as em                               # noqa: E402

CASES = {"f32": dict(FIFO_DEPTH=32, INIT_WAIT_CYCLES=40, REFRESH_INTERVAL_CYCLES=780, T_RAS_CYCLES=5,
                     CAS_LATENCY=2),
         "f4": dict(FIFO_DEPTH=4, INIT_WAIT_CYCLES=25, REFRESH_INTERVAL_CYCLES=60, T_RAS_CYCLES=7, CAS_LATENCY=3)}
CASE = os.environ.get("EFB_CASE", "f32")
P = CASES[CASE]
N = int(os.environ.get("EFB_N", "30000"))
SEED = int(os.environ.get("EFB_SEED", "20261021"))
PINS = ("cke", "ras_n", "cas_n", "we_n", "a")


@cocotb.test()
async def test_ext_frame_buffer_exact(dut):
    """Every clock: pins, flags and read data equal the model."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    m = em.ExtFrameBuffer(fifo_depth=P["FIFO_DEPTH"], init_wait=P["INIT_WAIT_CYCLES"], t_ras=P["T_RAS_CYCLES"],
                          cas=P["CAS_LATENCY"], refresh_interval=P["REFRESH_INTERVAL_CYCLES"])
    dut.rst_n.value = 0
    for s in ("wr_en", "rd_en", "wr_addr", "wr_data", "rd_addr0", "rd_addr1", "rd_addr2", "rd_addr3", "tb_dq"):
        getattr(dut, s).value = 0
    dut.tb_drive.value = 1
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    m.cycle()                                                     # the edge before the loop's first sample
    rows = [rng.randrange(1 << 9) for _ in range(4)]
    written = []
    sdram, open_row = {}, 0
    cov = dict(reads=0, writes=0, refresh=0, precharge=0, fifo_full=0)
    wr_burst = 0
    refreshes = []                                                # clocks of the refreshes after initialization
    for i in range(N):
        await FallingEdge(dut.clk)
        if wr_burst == 0 and rng.random() < 0.004:             # a burst now and then, idle (reads) between
            wr_burst = rng.randrange(1, 3 * P["FIFO_DEPTH"])
        we = int(wr_burst > 0 and rng.random() < 0.9)
        wa = (rng.choice(rows) << 10) | rng.randrange(1 << 10)
        wd = rng.getrandbits(24)
        re = int(rng.random() < 0.05)
        pick = [rng.choice(written) if written and rng.random() < 0.8 else rng.getrandbits(19) for _ in range(4)]
        dut.wr_en.value, dut.wr_addr.value, dut.wr_data.value = we, wa, wd
        dut.rd_en.value = re
        for k in range(4):
            getattr(dut, f"rd_addr{k}").value = pick[k]
        await Timer(1, unit="ns")
        o = m.cycle(we, wa, wd, re, pick)
        got = dict(cke=int(dut.sdram_cke.value), ras_n=int(dut.sdram_ras_n.value), cas_n=int(dut.sdram_cas_n.value),
                   we_n=int(dut.sdram_we_n.value), a=int(dut.sdram_a.value))
        for k in PINS:
            assert got[k] == o[k], f"clock {i}: {k} rtl {got[k]} model {o[k]} (state {m.s['state']})"
        assert int(dut.sdram_cs_n.value) == 0 and int(dut.sdram_ba.value) == 0 and int(dut.sdram_dqm.value) == 0
        for k in ("wr_ready", "wr_idle", "rd_ready", "rd_valid"):
            assert int(getattr(dut, k).value) == o[k], f"clock {i}: {k} rtl {getattr(dut, k).value} model {o[k]}"
        if o["rd_valid"]:
            rd = [int(getattr(dut, f"rd_data{k}").value) for k in range(4)]
            assert rd == o["rd_data"], f"clock {i}: read rtl {[hex(v) for v in rd]} model {o['rd_data']}"
            cov["reads"] += 1
        if we and o["wr_ready"]:
            written.append(wa)
            wr_burst -= 1
        cov["fifo_full"] += int(we and not o["wr_ready"] and m.s["init"])
        # the SDRAM responder samples the command at the coming edge
        cmd = (got["ras_n"], got["cas_n"], got["we_n"])
        col = got["a"] & 0x3FF
        if cmd == (0, 1, 1):                                      # ACTIVATE
            open_row = got["a"]
        elif cmd == (1, 0, 0):                                    # WRITE: the controller drives the bus
            bus = int(dut.dq_seen.value)
            assert bus & 0xFFFFFF == o["dq_out"], f"clock {i}: write data rtl {bus:#x} model {o['dq_out']:#x}"
            sdram[(open_row, col)] = bus
            cov["writes"] += 1
        elif cmd == (1, 0, 1):                                    # READ: the word from the next clock on
            dut.tb_dq.value = sdram.get((open_row, col), 0)
        elif cmd == (0, 0, 1):
            cov["refresh"] += 1
            if m.s["init"]:
                refreshes.append(i)
        elif cmd == (0, 1, 0):
            cov["precharge"] += 1
    # the refresh rate: the k-th refresh after the first comes at most k intervals plus one service delay later
    late = max((c - refreshes[0] - k * P["REFRESH_INTERVAL_CYCLES"] for k, c in enumerate(refreshes)), default=0)
    assert late <= 40, f"refreshes fall behind the schedule by {late} clocks"
    dut._log.info("%s: %d clocks compared, coverage %s, refresh lag at most %d clocks", CASE, N, cov, late)
    for k, v in cov.items():
        assert v, f"not covered: {k}"
