"""Shared parts of the NPU cocotb tests: a random-latency AXI4 slave on a byte-array memory (with AXI4 protocol
checks: INCR full-width bursts of 1 .. 16 beats inside a 4 KB page, WLAST on a burst's last beat, valid payloads
stable until their handshake; W may run ahead of AW)."""
from __future__ import annotations

import collections

from cocotb.triggers import FallingEdge, Timer


class Slave:
    """AXI4 slave: AW / W / B and AR / R with random ready / valid (busy: the probability of a ready / valid
    being low), bursts served in order."""

    def __init__(self, dut, rng, mem, busy=0.35):
        self.d, self.rng, self.mem = dut, rng, mem
        self.aw, self.ar = collections.deque(), collections.deque()
        self.wq = collections.deque()                 # (addr of beat) for every announced beat
        self.b = 0                                    # B responses owed
        self.wpend = collections.deque()              # W beats taken before their AW
        self.r = collections.deque()                  # (data, last) beats to return
        self.hold = {}                                # channel -> payload seen while valid and not ready
        self.bursts = 0
        self.busy = busy

    def check_burst(self, addr, ln, size, burst, ch):
        assert size == 5 and burst == 1, f"{ch}: size {size} burst {burst}"
        assert addr % 32 == 0 and 0 <= ln <= 15, f"{ch}: addr {addr:#x} len {ln}"
        assert addr // 4096 == (addr + 32 * ln) // 4096, f"{ch}: burst {addr:#x} + {ln + 1} beats crosses 4 KB"
        self.bursts += 1

    def stable(self, ch, valid, ready, payload):
        if valid and ch in self.hold:
            assert self.hold[ch] == payload, f"{ch} payload changed while valid"
        if valid and not ready:
            self.hold[ch] = payload
        else:
            self.hold.pop(ch, None)

    async def run(self):
        d, rng = self.d, self.rng
        wburst = collections.deque()                  # beats left in the bursts announced
        while True:
            await FallingEdge(d.clk)
            # drive this clock's ready / valid
            d.m_axi_awready.value = int(rng.random() >= self.busy)
            d.m_axi_arready.value = int(rng.random() >= self.busy)
            d.m_axi_wready.value = int(rng.random() >= self.busy)
            bv = self.b > 0 and rng.random() >= self.busy
            d.m_axi_bvalid.value = int(bv)
            rv = bool(self.r) and rng.random() >= self.busy
            d.m_axi_rvalid.value = int(rv)
            if rv:
                d.m_axi_rdata.value, d.m_axi_rlast.value = self.r[0]
            await Timer(1, unit="ns")
            # sample the handshakes of this clock
            aw = int(d.m_axi_awvalid.value), int(d.m_axi_awready.value)
            if aw[0]:
                p = (int(d.m_axi_awaddr.value), int(d.m_axi_awlen.value), int(d.m_axi_awsize.value),
                     int(d.m_axi_awburst.value))
                self.stable("AW", 1, aw[1], p)
                if aw[1]:
                    self.check_burst(*p, "AW")
                    for k in range(p[1] + 1):
                        self.wq.append(p[0] + 32 * k)
                    wburst.append(p[1] + 1)
            else:
                self.stable("AW", 0, 0, None)
            ar = int(d.m_axi_arvalid.value), int(d.m_axi_arready.value)
            if ar[0]:
                p = (int(d.m_axi_araddr.value), int(d.m_axi_arlen.value), int(d.m_axi_arsize.value),
                     int(d.m_axi_arburst.value))
                self.stable("AR", 1, ar[1], p)
                if ar[1]:
                    self.check_burst(*p, "AR")
                    for k in range(p[1] + 1):
                        a = p[0] + 32 * k
                        self.r.append((int.from_bytes(bytes(self.mem[a:a + 32]), "little"), int(k == p[1])))
            else:
                self.stable("AR", 0, 0, None)
            if int(d.m_axi_wvalid.value):
                p = (int(d.m_axi_wdata.value), int(d.m_axi_wstrb.value), int(d.m_axi_wlast.value))
                ready = int(d.m_axi_wready.value)
                self.stable("W", 1, ready, p)
                if ready:
                    self.wpend.append(p)                      # W may run ahead of its AW (legal)
            else:
                self.stable("W", 0, 0, None)
            while self.wpend and self.wq:                     # the beats whose address is known
                a = self.wq.popleft()
                data, strb, last = self.wpend.popleft()
                for k in range(32):
                    if strb >> k & 1:
                        self.mem[a + k] = (data >> 8 * k) & 0xFF
                wburst[0] -= 1
                assert bool(last) == (wburst[0] == 0), f"WLAST {last} with {wburst[0]} beats left"
                if wburst[0] == 0:
                    wburst.popleft()
                    self.b += 1
            if bv and int(d.m_axi_bready.value):
                self.b -= 1
            if rv and int(d.m_axi_rready.value):
                self.r.popleft()
