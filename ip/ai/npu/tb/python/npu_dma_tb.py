"""cocotb test of npu_dma (ip/ai/npu/src/npu_dma.sv) on a byte-array memory behind a random-latency AXI4 slave.

test_dma_random: random reads and writes (any byte address and length 1 .. 3000, across 4 KB pages, single
bytes, whole aligned beats), with random gaps on the write chunks and random back-pressure on the read
chunks and on every AXI channel. Every read chunk equals the memory (byte 0 = the requested byte, 32 bytes
but the last, RLAST of the stream on the last); every write lands exactly (bytes around it untouched),
wr_done_o only after the last B. Posted writes (wr_post_i, 40 % of the writes, often back to back): wr_done_o
once every byte is sent (B's may be owed), the next posted write (and reads) taken while they are; a write that
is not posted is never taken while a posted B is owed, wr_idle_o low until the last one is back. (Reads may pass
posted writes: the caller keeps them apart; this test reads only after wr_idle_o or a write that is not posted.) Queued reads
(20 % of the reads): 2 .. 6 requests issued back to back while the chunks come back, each request's bytes in
order with rd_last_o on its last chunk; the queue's full state (rd_ready_o low) reached. AXI checks: INCR full-width bursts of 1 .. 16 beats inside a 4 KB page,
WLAST on a burst's last beat, valid payloads stable until their handshake (W may run ahead of AW).
Cases (run_python.py): dma (RQ 8), dma_rq2 (RQ 2: the queue fills). Environment: NPU_SEED, NPU_N (requests,
default 400)."""
from __future__ import annotations

import collections
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from npu_tb_lib import Slave

SEED = int(os.environ.get("NPU_SEED", "20261025"))
CASE = os.environ.get("NPU_CASE", "dma")
N = int(os.environ.get("NPU_N", "400"))
LIMIT = 20000                                                     # clocks per request before a stall is reported
MEM = 1 << 16


async def idle(dut, n):
    """The caller's ordering rule: no read while a posted write is owed (wait for wr_idle_o)."""
    for _ in range(LIMIT):
        await Timer(1, unit="ns")
        if int(dut.wr_idle_o.value):
            return
        await FallingEdge(dut.clk)
    raise AssertionError(f"request {n}: wr_idle_o never high")


async def request(dut, kind, n, sl=None, cov=None):
    """Hold <kind>_req_i (set by the caller before a rising edge) until an edge with <kind>_ready_o high takes it.
    sl given: the request must not pass a posted write (no B owed when it is taken)."""
    for _ in range(LIMIT):
        await Timer(1, unit="ns")
        ready = int(getattr(dut, kind + "_ready_o").value)
        if ready and sl is not None:
            assert sl.b == 0 and int(dut.wr_idle_o.value), f"request {n}: {kind} taken with {sl.b} posted B owed"
        if not ready and sl is not None and sl.b and cov is not None:
            cov["held_for_posted"] += 1
        await RisingEdge(dut.clk)
        if ready:
            await FallingEdge(dut.clk)
            getattr(dut, kind + "_req_i").value = 0
            return
        await FallingEdge(dut.clk)
    st = {k: int(getattr(dut, k).value) for k in ("rd_busy", "out_left", "rx_left", "ar_left", "ar_v", "o_v", "flush",
                                                   "have_prev", "roff", "wr_busy", "in_left", "w_left", "aw_left",
                                                   "b_left", "st_pos", "w_n")}
    raise AssertionError(f"request {n}: {kind} not taken; state {st}")


@cocotb.test()
async def test_dma_random(dut):
    """Random reads and writes against a byte-array memory."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    rng = random.Random(SEED)
    mem = bytearray(rng.getrandbits(8) for _ in range(MEM))
    ref = bytearray(mem)
    sl = Slave(dut, rng, mem)
    for s in ("rd_req_i", "rd_addr_i", "rd_len_i", "rd_rdy_i", "wr_req_i", "wr_post_i", "wr_addr_i", "wr_len_i", "wr_valid_i",
              "wr_data_i", "wr_cnt_i", "m_axi_bid", "m_axi_bresp", "m_axi_rid", "m_axi_rresp"):
        getattr(dut, s).value = 0
    dut.rst_n.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(sl.run())
    cov = collections.Counter()

    def pick():
        k = rng.random()
        if k < 0.1:
            return rng.randrange(0, MEM - 64), rng.randrange(1, 4)                    # a few bytes
        if k < 0.2:
            return 32 * rng.randrange(MEM // 32 - 64), 32 * rng.randrange(1, 40)      # whole aligned beats
        if k < 0.35:
            a = 4096 * rng.randrange(1, MEM // 4096 - 1) - rng.randrange(1, 100)      # across a 4 KB page
            return a, rng.randrange(100, 1200)
        a = rng.randrange(0, MEM - 3100)
        return a, rng.randrange(1, 3000)

    chain = False                                                   # the last request a posted write: chain another
    for n in range(N):
        await FallingEdge(dut.clk)
        if not chain and rng.random() < 0.1:                            # queued reads
            await idle(dut, n)
            reqs = [pick() for _ in range(rng.randrange(2, 7))]
            got = [bytearray() for _ in reqs]

            async def issue():
                for i, (a, ln) in enumerate(reqs):
                    dut.rd_addr_i.value, dut.rd_len_i.value, dut.rd_req_i.value = a, ln, 1
                    await request(dut, "rd", n)
            task = cocotb.start_soon(issue())
            cur = 0
            for t in range(LIMIT * len(reqs)):
                if cur == len(reqs):
                    break
                await FallingEdge(dut.clk)
                dut.rd_rdy_i.value = int(rng.random() < 0.7)
                await Timer(1, unit="ns")
                if int(dut.rd_req_i.value) and not int(dut.rd_ready_o.value):
                    cov["read_queue_full"] += 1                     # a request waiting for room
                if int(dut.rd_valid_o.value) and int(dut.rd_rdy_i.value):
                    c, last = int(dut.rd_cnt_o.value), int(dut.rd_last_o.value)
                    a, ln = reqs[cur]
                    assert c == 32 or last, f"queued read {cur} {a:#x}+{ln}: chunk of {c} bytes before the last"
                    got[cur] += int(dut.rd_data_o.value).to_bytes(32, "little")[:c]
                    if last:
                        assert got[cur] == ref[a:a + ln], f"request {n}: queued read {cur} {a:#x} + {ln} differs"
                        cur += 1
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            dut.rd_rdy_i.value = 0
            await task
            assert cur == len(reqs), f"request {n}: queued reads stalled at {cur} of {len(reqs)}"
            cov["read_queued"] += 1
            chain = False
        elif not (chain and rng.random() < 0.6) and rng.random() < 0.5:   # a read
            await idle(dut, n)
            a, ln = pick()
            dut.rd_addr_i.value, dut.rd_len_i.value, dut.rd_req_i.value = a, ln, 1
            await request(dut, "rd", n)
            got, last = bytearray(), 0
            for t in range(LIMIT):
                if last:
                    break
                await FallingEdge(dut.clk)
                dut.rd_rdy_i.value = int(rng.random() < 0.7)
                await Timer(1, unit="ns")
                if int(dut.rd_valid_o.value) and int(dut.rd_rdy_i.value):
                    c, last = int(dut.rd_cnt_o.value), int(dut.rd_last_o.value)
                    assert c == 32 or last, f"read {a:#x}+{ln}: chunk of {c} bytes before the last"
                    got += int(dut.rd_data_o.value).to_bytes(32, "little")[:c]
            await RisingEdge(dut.clk)                               # the last chunk's handshake
            await FallingEdge(dut.clk)
            dut.rd_rdy_i.value = 0
            assert last, f"request {n}: read {a:#x} + {ln} stalled after {len(got)} bytes"
            assert got == ref[a:a + ln], f"request {n}: read {a:#x} + {ln} differs"
            cov["read"] += 1
            cov["read_unaligned"] += int(a % 32 != 0)
            chain = False
        else:                                                       # a write
            post = (chain and rng.random() < 0.6) or rng.random() < 0.4
            a, ln = (rng.randrange(0, MEM - 64), rng.randrange(1, 40)) if post and chain else pick()   # short: B owed
            data = bytes(rng.getrandbits(8) for _ in range(ln))
            dut.wr_addr_i.value, dut.wr_len_i.value, dut.wr_req_i.value, dut.wr_post_i.value = a, ln, 1, int(post)
            if post and sl.b:
                cov["posted_back_to_back"] += 1
            await request(dut, "wr", n, None if post else sl, cov)
            dut.wr_post_i.value = 0
            pos, done = 0, False
            for t in range(LIMIT):
                if done:
                    break
                await FallingEdge(dut.clk)
                send = pos < ln and rng.random() < 0.7
                if send:
                    c = min(32, ln - pos)
                    dut.wr_data_i.value = int.from_bytes(data[pos:pos + c], "little")
                    dut.wr_cnt_i.value = c
                dut.wr_valid_i.value = int(send)
                await Timer(1, unit="ns")
                if send and int(dut.wr_rdy_o.value):
                    pos += c
                if int(dut.wr_done_o.value):
                    assert pos == ln and (post or sl.b == 0), f"write {a:#x}+{ln}: done with {ln - pos} bytes unsent / B owed"
                    done = True
            dut.wr_valid_i.value = 0
            assert done, f"request {n}: write {a:#x} + {ln} stalled at {pos} bytes"
            ref[a:a + ln] = data
            assert mem == ref, f"request {n}: write {a:#x} + {ln}: memory differs"
            cov["write"] += 1
            cov["write_posted"] += int(post)
            cov["write_unaligned"] += int(a % 32 != 0 or ln % 32 != 0)
            chain = post
            if post and rng.random() < 0.3:                         # wait for wr_idle_o: every B back
                for t in range(LIMIT):
                    await FallingEdge(dut.clk)
                    if int(dut.wr_idle_o.value):
                        break
                    assert sl.b or t < 3, f"request {n}: wr_idle_o low with no B owed"
                assert int(dut.wr_idle_o.value) and sl.b == 0, f"request {n}: wr_idle_o high with {sl.b} B owed"
                cov["idle_wait"] += 1
                chain = False
    dut._log.info("npu_dma: %d requests, %d bursts, coverage %s", N, sl.bursts, dict(cov))
    for k in ("read", "write", "read_unaligned", "write_unaligned", "write_posted", "posted_back_to_back",
              "held_for_posted", "idle_wait", "read_queued") + (("read_queue_full",) if CASE == "dma_rq2" else ()):
        assert cov[k], f"not covered: {k}"
