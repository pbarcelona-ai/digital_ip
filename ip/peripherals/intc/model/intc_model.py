"""intc model (Python model of ip/peripherals/intc/src/intc.sv), clock exact: NUM_IRQ sources with enable,
edge / level, active low and software set; PENDING (edge sources: latched rising edges and the rise of the
clock; level sources: the input; a software set of either type latched too; write 1 to clear, a set wins),
VECTOR (lowest pending enabled, registered), MASKED; irq = the registered |MASKED.

Clock behaviour (the state of clock n, as the RTL computes it):
  lvl(n)  = irq_in(n - 2) ^ ACTIVE_LOW(n)            (two-flop synchroniser; irq_in before clock 0 is 0)
  rise(n) = lvl(n) & ~lvl(n - 1)
  pend_edge(n) = pend_edge(n - 1) & ~clear(n - 1) | rise(n - 1) & EDGE_TYPE(n - 1) | set(n - 1)
  PENDING(n) = EDGE_TYPE & (pend_edge | rise) | ~EDGE_TYPE & (lvl | pend_edge);  MASKED(n) = PENDING & ENABLE
  VECTOR(n), irq(n) from MASKED(n - 1)
so an input change shows in PENDING / MASKED 2 clocks later, in VECTOR and irq 3 clocks later. Register
values written in clock w (the cfg_* value of clock w) act in w (ENABLE, EDGE_TYPE, ACTIVE_LOW); a PENDING
clear or a SOFT_SET written in w changes pend_edge from w + 1.
The state is computed when asked, from logs: the host provides sim (the clock: sim.now; sim.at schedules
the clocks at which irq may change, so an event-driven host sees them) and irq_in(n), the input vector in
clock n (n <= sim.now), and calls input_changed(t) when it changes in clock t (t >= the clocks already
asked about). Register writes come through the register map (RegMap); set_cfg(name, value) sets ENABLE /
EDGE_TYPE / ACTIVE_LOW from the current clock without a bus write (tests)."""
import heapq

from regs import RegMap, ip_regs

CFG = ("ENABLE", "EDGE_TYPE", "ACTIVE_LOW")


class Intc:
    """intc: n sources (host.irq_in), latched edges, software set, VECTOR; irq() the CPU's input."""

    def __init__(self, host, n=17):
        self.host, self.n = host, n
        self.mask = (1 << n) - 1
        self.r = RegMap(ip_regs(__file__, "intc"), {"NUM_IRQ": n})
        self.log = {k: [(-1 << 62, self.r.get(k))] for k in CFG}  # (first clock, value)
        self.clear, self.sset = {}, {}                  # clock -> bits written to PENDING / SOFT_SET
        self.cand = []                                  # clocks at which pend_edge may change (heap)
        self.pe, self.pe_t = 0, 0                       # pend_edge, valid from clock pe_t
        self.pe_hist = [(0, 0)]                         # (clock, pend_edge) changes
        self.r.sts = self._sts
        self.r.on_write = self._w

    # -- inputs and configuration over time
    def _val(self, k, n):
        log = self.log[k]
        for t, v in reversed(log):
            if t <= n:
                return v
        return log[0][1]

    def _set(self, k, v):
        now = self.host.sim.now
        log = self.log[k]
        if log[-1][1] == v:
            return
        if log[-1][0] == now:
            log[-1] = (now, v)
        else:
            log.append((now, v))
            if len(log) > 4096:
                del log[:2048]
        self._wake(now + 1)
        if k == "ACTIVE_LOW":                           # lvl changes now: a rise, pend_edge from now + 1
            self._cand(now + 1)
            self._wake(now + 2)

    def set_cfg(self, name, value):
        self.r.set(name, value)
        self._set(name, self.r.get(name))

    def input_changed(self, t):
        """irq_in changes in clock t: lvl at t + 2, pend_edge at t + 3, irq at t + 3 / t + 4."""
        self._cand(t + 3)
        self._wake(t + 3)
        self._wake(t + 4)

    def _cand(self, c):
        heapq.heappush(self.cand, c)

    def _wake(self, t):
        if t > self.host.sim.now:
            self.host.sim.at(t, lambda: None)

    def _lvl(self, n):
        if n < 0:
            return 0
        raw = self.host.irq_in(n - 2) if n >= 2 else 0
        return (raw ^ self._val("ACTIVE_LOW", n)) & self.mask

    def _rise(self, n):
        return self._lvl(n) & ~self._lvl(n - 1) & self.mask

    def _pend_edge(self, n):
        """pend_edge(n): the candidates up to n processed in order."""
        while self.cand and self.cand[0] <= n:
            c = heapq.heappop(self.cand)
            if c <= self.pe_t:
                continue
            p = c - 1
            pe = ((self.pe & ~self.clear.pop(p, 0)) | (self._rise(p) & self._val("EDGE_TYPE", p))
                  | self.sset.pop(p, 0)) & self.mask
            if pe != self.pe:
                self.pe_hist.append((c, pe))
                if len(self.pe_hist) > 64:
                    del self.pe_hist[:32]
            self.pe, self.pe_t = pe, c
        for t, v in reversed(self.pe_hist):             # n may be before the last change (irq: n - 1)
            if t <= n:
                return v
        return self.pe_hist[0][1]

    # -- the state of clock n
    def pending(self, n=None):
        n = self.host.sim.now if n is None else n
        edg = self._val("EDGE_TYPE", n)
        pe, lv, rise = self._pend_edge(n), self._lvl(n), self._rise(n)
        return ((edg & (pe | rise)) | (~edg & (lv | pe))) & self.mask

    def masked(self, n=None):
        n = self.host.sim.now if n is None else n
        return self.pending(n) & self._val("ENABLE", n)

    def irq(self):
        return self.masked(self.host.sim.now - 1) != 0

    def _sts(self, name, i):
        if name == "PENDING":
            return self.pending()
        if name == "MASKED":
            return self.masked()
        if name == "VECTOR":
            m = self.masked(self.host.sim.now - 1)
            if not m:
                return 0
            return (1 << 31) | ((m & -m).bit_length() - 1)
        return 0

    def _w(self, name, i, d):
        now = self.host.sim.now
        if name in CFG:
            self._set(name, self.r.get(name))
        elif name in ("PENDING", "SOFT_SET"):
            book = self.clear if name == "PENDING" else self.sset
            book[now] = book.get(now, 0) | (d & self.mask)
            self._cand(now + 1)
            self._wake(now + 2)
