"""uart model (Python model of ip/peripherals/uart/src/uart.sv with uart_baud, uart_tx and uart_rx), event
driven with the RTL's clock timing.

Registers (uart_regs.json): CTRL [0] TX_EN [1] RX_EN [2] parity [3] odd [4] 2 stop bits [5] loopback
[7:6] 8 - data bits (reset 0x3); FCW (16 x baud / clock x 2**32); STATUS [0] TX busy [1] RX busy [2] RX
word available [8] frame error [9] parity error [10] overrun (W1C, a set in the same clock wins)
[30:16] RX FIFO level; ERR_CNT (frames with an error). TX bytes come from the TX FIFO (AXI-Stream slave),
received bytes go to the RX FIFO (master; tuser = an error): ip_axis_fifo models of FIFO_DEPTH.

Timing (clocks): the baud generator adds FCW to a 32-bit accumulator every clock (zero at reset); its carry
is the 16x tick of the next clock; ticks are counted in closed form (Baud). TX: a byte is taken in a clock
the engine is idle and enabled and the FIFO shows one (load clock L); TXD is low from L + 1; each bit
(start, data LSB first, parity, stop, second stop) lasts 16 ticks counted from the clock after the previous
bit's last tick (from L + 1 for the start bit), the next bit is on TXD the clock after; BUSY from L + 1 to
the last stop bit's 16th tick. RX: the line is seen 3 clocks late (synchroniser and a register: rxs(n) =
rxd(n - 3)); idle, armed (rxs high in an idle clock since the last frame) and enabled, a low rxs starts a
frame the next clock; the start bit is checked at its 8th tick (high: a glitch, back to idle), then every
16th tick samples a data bit, the parity bit and the stop bit; the word is valid the clock after the stop
sample (into the RX FIFO, dropped with overrun when it is full), the error flags and ERR_CNT a clock later.
CTRL is taken as constant during a frame (the firmware sets it once); an FCW change reschedules the bits in
flight with the ticks they still need.
The RX line is the TX line with loopback, or rxd_source (a function of the clock; None: the TX line, py_soc's
board loopback); the host of an external line calls rx_line_fell(t) when it falls. Hooks: on_tx_take(t),
on_rx_push(t), on_char(c) at a TX frame's end, on_txd_fell(t) when TXD falls in clock t (another UART's
RX line). The host provides sim (event queue, aclk) and update_irq()."""
from ip_axis_fifo_model import AxisFifo
from regs import RegMap, ip_regs

TWO32 = 1 << 32


def fcw_of(clk_hz, baud):
    """FCW at reset (uart_top's FCW64): round(16 baud 2**32 / clk)."""
    return ((baud * 16 << 32) + (clk_hz >> 1)) // clk_hz


class Baud:
    """uart_baud: the accumulator during clock tb is ab, FCW fb from then on; S(n) = ab + (n - tb) fb."""

    def __init__(self, fcw):
        self.tb, self.ab, self.fb = 0, 0, fcw

    def s(self, n):
        return self.ab + (n - self.tb) * self.fb

    def ticks(self, a, b):
        """Ticks in clocks a + 1 .. b (a, b >= tb)."""
        return self.s(b) // TWO32 - self.s(a) // TWO32

    def nth(self, a, k):
        """The clock of the k-th tick after clock a (k >= 1), or None (FCW 0)."""
        if self.fb == 0:
            return None
        target = (self.s(a) // TWO32 + k) * TWO32
        return self.tb + -(-(target - self.ab) // self.fb)

    def change(self, t, fcw):
        """FCW fcw from clock t (the accumulator keeps its value; the old FCW made clock t's tick)."""
        self.ab, self.tb, self.fb = self.s(t) % TWO32, t, fcw


class UartCore:
    """uart: registers, FIFOs, baud generator, TX and RX engines."""

    def __init__(self, sim, update_irq, clk_hz=100_000_000, baud=115_200, fifo_depth=512):
        self.sim, self.update_irq = sim, update_irq
        self.r = RegMap(ip_regs(__file__, "uart"), {"FCW_RST": fcw_of(clk_hz, baud)})
        self.txf, self.rxf = AxisFifo(fifo_depth), AxisFifo(fifo_depth)
        self.baud = Baud(self.r.get("FCW"))
        self.ferr = self.perr = self.ovr = False
        self.err_cnt = 0
        self.rxd_source = None
        self.txd = [(0, 1)]                              # TXD transitions (clock, level)
        self.tx_busy = False                             # STATUS: the TX state is not idle
        self.tx_active = False                           # the TX engine holds a frame (from its load clock)
        self.tx_from = 0                                 # first clock the TX engine may load again
        self.rx_state = "idle"                           # STATUS: the RX state (from the clock after a decision)
        self.rx_active = False                           # the RX engine is in a frame
        self.rx_idle_from = 0
        self.ev = {"tx": None, "rx": None}               # per engine: (anchor clock, ticks, handler, token)
        self.tok = 0
        self.on_tx_take = self.on_rx_push = self.on_char = self.on_txd_fell = None
        self.r.sts = self._sts
        self.r.on_write = self._w

    # -- registers
    def _sts(self, name, i):
        if name == "STATUS":
            self.rxf.sync(self.sim.now)
            return (int(self.tx_busy) | int(self.rx_state != "idle") << 1 | int(self.rxf.tvalid()) << 2
                    | int(self.ferr) << 8 | int(self.perr) << 9 | int(self.ovr) << 10
                    | (self.rxf.level() & 0x7FFF) << 16)
        if name == "ERR_CNT":
            return self.err_cnt & 0xFFFFFFFF
        return 0

    def _w(self, name, i, d):
        now = self.sim.now
        if name == "STATUS":                             # W1C from the next clock
            self.ferr = self.ferr and not d & 0x100
            self.perr = self.perr and not d & 0x200
            self.ovr = self.ovr and not d & 0x400
            self.update_irq()
        elif name == "FCW":
            self._fcw(now, d & 0xFFFFFFFF)
        elif name == "CTRL":
            self.sim.at(now, self._kick)

    def ctrl(self):
        c = self.r.get("CTRL")
        return dict(tx_en=c & 1, rx_en=(c >> 1) & 1, par=(c >> 2) & 1, odd=(c >> 3) & 1, stop2=(c >> 4) & 1,
                    loop=(c >> 5) & 1, bits=8 - ((c >> 6) & 3))

    # -- tick-timed events
    def _after_ticks(self, eng, a, k, fn):
        """fn(clock) at the k-th tick after clock a, replacing the engine's pending event."""
        self.tok += 1
        tok = self.tok
        self.ev[eng] = (a, k, fn, tok)
        n = self.baud.nth(a, k)
        if n is not None:
            self.sim.at(n, lambda: self._fire(eng, tok, n))

    def _fire(self, eng, tok, n):
        ev = self.ev[eng]
        if ev is not None and ev[3] == tok:
            self.ev[eng] = None
            ev[2](n)

    def _fcw(self, t, fcw):
        """A new FCW from clock t: the events in flight keep the ticks they have counted."""
        pend = [(eng, ev) for eng, ev in self.ev.items() if ev is not None]
        rem = [(eng, ev[1] - (self.baud.ticks(ev[0], t) if t > ev[0] else 0), ev[2]) for eng, ev in pend]
        self.baud.change(t, fcw)
        for eng, k, fn in rem:
            self._after_ticks(eng, t, max(1, k), fn)

    # -- streams (host side)
    def push_tx(self, t, byte, last=0):
        """s_axis handshake in clock t: True if accepted."""
        ok = self.txf.push(t, (byte & 0xFF, last, 0))
        if ok:
            self.sim.at(t + 1, self._kick)
        return ok

    def take_rx(self, t):
        """m_axis handshake in clock t: (byte, last) or None."""
        w = self.rxf.take(t)
        return None if w is None else (w[0], w[1])

    def irq(self):
        """The IP has no interrupt output (py_soc: its data port's)."""
        return False

    # -- lines
    def txd_at(self, n):
        v = 1
        for t, lv in reversed(self.txd):
            if t <= n:
                return lv
        return v

    def _internal(self):
        return self.ctrl()["loop"] or self.rxd_source is None

    def rxd_at(self, n):
        return self.txd_at(n) if self._internal() else self.rxd_source(n)

    def _high_between(self, a, b):
        """The RX line was high in some clock of a .. b."""
        if b < a:
            return False
        if not self._internal():
            return any(self.rxd_source(n) for n in range(a, b + 1))
        return bool(self.txd_at(a)) or any(lv for t, lv in self.txd if a < t <= b)

    def _set_txd(self, t, lv):
        if self.txd[-1][1] != lv:
            self.txd.append((t, lv))
            if len(self.txd) > 4096:
                del self.txd[:2048]
            if lv == 0 and self._internal():
                self.sim.at(t + 3, self._rx_watch)       # rxs falls 3 clocks later
            if lv == 0 and self.on_txd_fell:
                self.on_txd_fell(t)

    def rx_line_fell(self, t):
        """The external RX line (rxd_source) fell in clock t."""
        self.sim.at(t + 3, self._rx_watch)

    # -- TX engine
    def _kick(self):
        """Load the next byte when idle, enabled and the TX FIFO shows one."""
        now = self.sim.now
        if self.tx_active or not self.ctrl()["tx_en"] or now < self.tx_from:
            return
        v = self.txf.first_valid(now)
        if v is None:
            return
        if v > now:
            self.sim.at(v, self._kick)
            return
        byte = self.txf.take(now)[0]
        if self.on_tx_take:
            self.on_tx_take(now)
        c = self.ctrl()
        bits = [(byte >> k) & 1 for k in range(c["bits"])]
        frame = [0] + bits
        if c["par"]:
            p = 0
            for b in bits:
                p ^= b
            frame.append(p ^ c["odd"])
        frame += [1, 1] if c["stop2"] else [1]
        self.tx_active = True
        self.sim.at(now + 1, self._tx_start)
        self._set_txd(now + 1, 0)
        self._after_ticks("tx", now, 16, lambda n: self._tx_end(n, frame, 0, byte))

    def _tx_end(self, n, frame, k, byte):
        """Bit k ended at clock n's tick."""
        if k + 1 < len(frame):
            self._set_txd(n + 1, frame[k + 1])
            self._after_ticks("tx", n, 16, lambda m: self._tx_end(m, frame, k + 1, byte))
            return
        self.tx_from = n + 1
        self.sim.at(n + 1, self._tx_idle)
        if self.on_char:
            self.on_char(byte)

    def _tx_start(self):
        self.tx_busy = True
        self.update_irq()

    def _tx_idle(self):
        self.tx_busy = self.tx_active = False
        self.update_irq()
        self._kick()

    # -- RX engine
    def _rx_watch(self):
        """rxs may be low in this clock: a start bit if idle, armed and enabled."""
        now = self.sim.now
        if self.rx_active or self.rxd_at(now - 3) or not self.ctrl()["rx_en"]:
            return
        if not self._high_between(self.rx_idle_from - 3, now - 4):
            return                                       # not armed: no high line since the last frame
        self.rx_active = True
        self.sim.at(now + 1, self._rx_start)
        self._after_ticks("rx", now, 8, self._rx_start_mid)

    def _rx_start(self):
        self.rx_state = "start"
        self.update_irq()

    def _rx_start_mid(self, n):
        if self.rxd_at(n - 3):                           # a glitch: back to idle
            self._rx_to_idle(n + 1)
            return
        self.rx_word, self.rx_par, self.rx_k, self.rx_perr = 0, 0, 0, 0
        self._after_ticks("rx", n, 16, self._rx_sample)

    def _rx_sample(self, n):
        """A data, parity or stop sample at clock n's tick."""
        c = self.ctrl()
        b = self.rxd_at(n - 3)
        if self.rx_k < c["bits"]:
            self.rx_word |= b << self.rx_k
            self.rx_par ^= b
            self.rx_k += 1
            if self.rx_k == c["bits"] and not c["par"]:
                self.rx_k = 99                           # the stop bit next
            self._after_ticks("rx", n, 16, self._rx_sample)
            return
        if self.rx_k == c["bits"]:                       # the parity bit
            self.rx_perr = int((self.rx_par ^ c["odd"]) != b)
            self.rx_k = 99
            self._after_ticks("rx", n, 16, self._rx_sample)
            return
        ferr, perr, word = int(not b), self.rx_perr & c["par"], self.rx_word
        self._rx_to_idle(n + 1)
        self.sim.at(n + 1, lambda: self._rx_valid(n + 1, word, ferr, perr))

    def _rx_to_idle(self, t):
        self.rx_idle_from = t
        self.sim.at(t, self._rx_idle)

    def _rx_idle(self):
        self.rx_state = "idle"
        self.rx_active = False
        self.update_irq()
        self._rx_watch()

    def _rx_valid(self, t, word, ferr, perr):
        """The received word in clock t: into the RX FIFO (dropped when full: overrun); flags a clock later."""
        self.rxf.sync(t)
        full = self.rxf.full()
        if not full:
            self.rxf.push(t, (word, 0, int(bool(ferr or perr))))
            if self.on_rx_push:
                self.on_rx_push(t)
        self.sim.at(t + 1, lambda: self._rx_flags(ferr, perr, full))

    def _rx_flags(self, ferr, perr, ovr):
        self.ferr |= bool(ferr)
        self.perr |= bool(perr)
        self.ovr |= ovr
        self.err_cnt += int(bool(ferr or perr))
        self.update_irq()
