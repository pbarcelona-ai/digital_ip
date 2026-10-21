"""spi_master model (Python model of ip/peripherals/spi_master/src/spi_master.sv and spi_engine.sv), event driven
with the RTL's clock timing and pins.

Registers (spi_master_regs.json): CTRL [0] EN [1] CPOL [2] CPHA [3] LSB first [15:8] chip select (its low
clog2(NUM_CS) bits are used; a value >= NUM_CS selects none); DIV (SCLK
half period = DIV + 1 clocks, below 2 acts as 2); WORD_LEN (1..DATA_W, other values act as DATA_W); STATUS
[0] BUSY [1] RX overrun (W1C, a set in the same clock wins) [31:16] RX FIFO level. Words to send come from
the TX FIFO (AXI-Stream slave, tlast ends a chip-select burst), received words go to the RX FIFO (master,
tlast as sent): ip_axis_fifo models of FIFO_DEPTH.

Timing (clocks; D = DIV + 1): a word is taken in a clock L the engine is idle and enabled and the TX FIFO
shows one; chip select from L + 1 (CS_N low from L + 2); SCLK edge k (k = 0 .. 2 len - 1) at clock
L + 2 D + k D (SCLK toggles the clock after); MISO is sampled at the sample edges (even with CPHA 0, odd
with CPHA 1) as it was 2 clocks before (synchroniser); MOSI: with CPHA 0 the first bit from L + 1, the
next ones the clock after each odd edge; with CPHA 1 each bit the clock after each even edge; after the
last edge a hold half period, then DONE at L + (2 len + 2) D + 1: the word valid the clock after (into the
RX FIFO, dropped with overrun when it is full), the engine idle then (BUSY from L + 1 to DONE), chip select
released then after a tlast word (CS_N high a clock later); idle without chip select, MOSI goes low and
SCLK rests at CPOL. CTRL / DIV / WORD_LEN are taken as constant while a burst runs.
MISO: miso_source(n) (a function of the clock), None: MOSI looped back (py_soc's board).
Hooks for a host: on_tx_take(t), on_rx_push(t). The host provides sim (event queue, aclk), update_irq()."""
from ip_axis_fifo_model import AxisFifo
from regs import RegMap, ip_regs


class Line:
    """A pin as its transitions (clock, level): the level in clock n."""

    def __init__(self, level):
        self.ev = [(0, level)]

    def set(self, t, level):
        if self.ev[-1][1] != level:
            if self.ev[-1][0] == t:
                self.ev[-1] = (t, level)
            else:
                self.ev.append((t, level))
            if len(self.ev) > 4096:
                del self.ev[:2048]

    def at(self, n):
        for t, lv in reversed(self.ev):
            if t <= n:
                return lv
        return self.ev[0][1]


class SpiCore:
    """spi_master: registers, FIFOs, the engine and its pins (sclk, mosi, cs_n)."""

    def __init__(self, sim, update_irq, clk_hz=100_000_000, sclk_hz=1_000_000, data_w=32, num_cs=4,
                 fifo_depth=512):
        self.sim, self.update_irq = sim, update_irq
        self.data_w, self.num_cs = data_w, num_cs
        self.r = RegMap(ip_regs(__file__, "spi_master"), {"DIV_RST": clk_hz // (2 * sclk_hz) - 1, "DATA_W": data_w})
        self.txf, self.rxf = AxisFifo(fifo_depth), AxisFifo(fifo_depth)
        self.sclk, self.mosi = Line(0), Line(0)
        self.cs_n = Line((1 << num_cs) - 1)
        self.miso_source = None
        self.busy = False                                # STATUS.BUSY (the state is not idle)
        self.active = False                              # the engine holds a word (from its load clock)
        self.cs_active = False
        self.ovr = False
        self.free_from = 0                               # first clock the engine may load again
        self.on_tx_take = self.on_rx_push = None
        self.r.sts = self._sts
        self.r.on_write = self._w

    # -- registers
    def _sts(self, name, i):
        if name == "STATUS":
            self.rxf.sync(self.sim.now)
            return int(self.busy) | int(self.ovr) << 1 | (self.rxf.level() & 0xFFFF) << 16
        return 0

    def _w(self, name, i, d):
        if name == "STATUS":
            if d & 2:
                self.ovr = False                         # from the next clock (a set then wins)
            self.update_irq()
        elif name == "CTRL":
            self._idle_pins(self.sim.now)
            self.sim.at(self.sim.now, self._kick)

    def cfg(self):
        c = self.r.get("CTRL")
        wl = self.r.get("WORD_LEN")
        div = self.r.get("DIV")
        return dict(en=c & 1, cpol=(c >> 1) & 1, cpha=(c >> 2) & 1, lsb=(c >> 3) & 1, cs=(c >> 8) & 0xFF,
                    wl=self.data_w if wl == 0 or wl > self.data_w else wl, d=max(2, div) + 1)

    def irq(self):
        """The IP has no interrupt output (py_soc: its data port's)."""
        return False

    # -- streams (host side)
    def push_tx(self, t, word, last=0):
        ok = self.txf.push(t, (word & ((1 << self.data_w) - 1), last, 0))
        if ok:
            self.sim.at(t + 1, self._kick)
        return ok

    def take_rx(self, t):
        w = self.rxf.take(t)
        return None if w is None else (w[0], w[1])

    def miso_at(self, n):
        return self.mosi.at(n) if self.miso_source is None else self.miso_source(n)

    def _cs_n(self, active):
        csw = (self.num_cs - 1).bit_length() if self.num_cs > 1 else 1
        sel = self.cfg()["cs"] & ((1 << csw) - 1)        # the RTL uses CTRL[8 +: clog2(NUM_CS)]
        return ((1 << self.num_cs) - 1) & ~((1 << sel) if active and sel < self.num_cs else 0)

    def _idle_pins(self, t):
        """Idle levels from clock t + 1: SCLK at CPOL, CS_N by the chip select."""
        if not self.active:
            c = self.cfg()
            self.sclk.set(t + 1, c["cpol"])
            self.cs_n.set(t + 1, self._cs_n(self.cs_active))

    # -- the engine
    def _kick(self):
        now = self.sim.now
        if self.active or now < self.free_from or not self.cfg()["en"]:
            return
        v = self.txf.first_valid(now)
        if v is None:
            return
        if v > now:
            self.sim.at(v, self._kick)
            return
        word, last, _ = self.txf.take(now)
        if self.on_tx_take:
            self.on_tx_take(now)
        self._word(now, word, last)

    def _word(self, L, word, last):
        """The whole word from its load clock L: pins, the received bits and the end events."""
        c = self.cfg()
        d, wl, cpha, lsb = c["d"], c["wl"], c["cpha"], c["lsb"]
        self.active = True
        self.sim.at(L + 1, self._set_busy)
        order = list(range(wl)) if lsb else list(range(wl - 1, -1, -1))
        self.sclk.set(L + 1, c["cpol"])
        if not self.cs_active:
            self.cs_active = True
        self.cs_n.set(L + 2, self._cs_n(True))
        if not cpha:
            self.mosi.set(L + 1, (word >> order[0]) & 1)
        samples, nbit, tbit = [], 0, 0                   # (clock, bit position) of the samples
        level = c["cpol"]
        e0 = L + 2 * d
        last_edge = 2 * wl - 1
        for k in range(2 * wl):
            e = e0 + k * d
            level ^= 1
            self.sclk.set(e + 1, level)
            if (k & 1) == cpha:                          # sample edge
                samples.append((e - 2, order[nbit]))
                nbit += 1
            else:                                        # shift edge
                if cpha and k == 0:
                    self.mosi.set(e + 1, (word >> order[0]) & 1)
                elif k != last_edge:
                    tbit += 1
                    self.mosi.set(e + 1, (word >> order[tbit]) & 1)
        done = e0 + last_edge * d + d + 1                # DONE clock
        self.free_from = done + 1
        self.sim.at(done + 1, lambda: self._done(done + 1, samples, last))

    def _set_busy(self):
        self.busy = True
        self.update_irq()

    def _done(self, t, samples, last):
        """Clock t: the word valid (RX FIFO or overrun), the engine idle, chip select released after tlast."""
        rx = 0
        for n, pos in samples:                           # MISO as the synchroniser saw it
            rx |= self.miso_at(n) << pos
        self.busy = self.active = False
        self.rxf.sync(t)
        if self.rxf.full():
            self.sim.at(t + 1, self._overrun)
        else:
            self.rxf.push(t, (rx, last, 0))
            if self.on_rx_push:
                self.on_rx_push(t)
        if last:
            self.cs_active = False
            self.cs_n.set(t + 1, self._cs_n(False))
        self.update_irq()
        self._kick()
        if last and not self.active:
            self.mosi.set(t + 1, 0)                      # idle without chip select: MOSI low

    def _overrun(self):
        self.ovr = True
        self.update_irq()
