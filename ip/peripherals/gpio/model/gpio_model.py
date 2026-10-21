"""gpio model (Python model of ip/peripherals/gpio/src/gpio.sv), event driven with the RTL's clock timing.

Registers (gpio_regs.json): OUT (a write sets all outputs; reads them), DIR (1 = output), IN (the pins, two-flop
synchronised), SET / CLEAR / TOGGLE (atomic), INT_EN, RISE_EN, FALL_EN, INT_STATUS (W1C: edges seen; a set in
the same clock wins); irq = |(INT_STATUS & INT_EN).

Timing (clocks): OUT / SET / CLEAR / TOGGLE written in clock w change the outputs from w + 1; DIR acts in w;
a pin (pad) level of clock p is IN from p + 2; an edge of the pad in clock p (its level differs from p - 1)
sets INT_STATUS from p + 3 when RISE_EN / FALL_EN enable it in clock p + 2; irq() is the condition of the
current clock (the RTL registers it: irq_o one clock later).
The pad: board_in(out, dir) gives the board's levels; with loopback, driven pins read their own output (the
pad level is the output where DIR is 1). The host calls sample() whenever the board's levels may have changed
(register writes resample by themselves). on_out(out) is told about output changes.
The host (soc) provides sim (the event queue) and update_irq()."""
from regs import RegMap, ip_regs


class Gpio:
    """gpio: 32 pins (WIDTH), output / direction, synchronised input, edge capture, irq()."""

    def __init__(self, soc, board_in=lambda o, t: 0, loopback=False, on_out=None, width=32):
        self.soc, self.width = soc, width
        self.mask = (1 << width) - 1
        self.r = RegMap(ip_regs(__file__, "gpio"), {"WIDTH": width})
        self.out = 0
        self.board_in = board_in
        self.loopback = loopback
        self.on_out = on_out or (lambda v: None)
        self.pad_ev = [(-10, 0)]                         # pad transitions (clock, levels); 0 before reset
        self.edge_due = set()                            # pad clocks whose edge detection is scheduled
        self.r.sts = self._sts
        self.r.on_write = self._w

    def pad_now(self):
        """The pad levels for the present outputs and board."""
        drive = self.r.get("DIR")
        board = self.board_in(self.out, drive)
        if self.loopback:
            return ((self.out & drive) | (board & ~drive)) & self.mask
        return board & self.mask

    def pad_at(self, n):
        for t, v in reversed(self.pad_ev):
            if t <= n:
                return v
        return 0

    def _sts(self, name, i):
        if name == "OUT":
            return self.out
        if name == "IN":
            return self.pad_at(self.soc.sim.now - 2)
        return 0

    def _w(self, name, i, d):
        now = self.soc.sim.now
        if name in ("OUT", "SET", "CLEAR", "TOGGLE"):
            new = {"OUT": d, "SET": self.out | d, "CLEAR": self.out & ~d, "TOGGLE": self.out ^ d}[name] & self.mask
            self.soc.sim.at(now + 1, lambda: self._set_out(new))
        self.sample()

    def _set_out(self, v):
        self.out = v
        self.on_out(v)
        self.sample()

    def sample(self):
        """The pad may have changed in the present clock: record it and schedule its edge detection."""
        now = self.soc.sim.now
        v = self.pad_now()
        if self.pad_ev[-1][0] == now:
            self.pad_ev[-1] = (now, v)                   # the clock's final level
        elif v != self.pad_ev[-1][1]:
            self.pad_ev.append((now, v))
            if len(self.pad_ev) > 4096:
                del self.pad_ev[:2048]
        else:
            return
        if now not in self.edge_due:
            self.edge_due.add(now)
            self.soc.sim.at(now + 2, lambda: self._edge(now))
        self.soc.update_irq()

    def _edge(self, p):
        """Clock p + 2: the synchronised edge of clock p, captured when enabled now; INT_STATUS a clock later."""
        self.edge_due.discard(p)
        v, old = self.pad_at(p), self.pad_at(p - 1)
        bits = ((v & ~old & self.r.get("RISE_EN")) | (~v & old & self.r.get("FALL_EN"))) & self.mask
        if bits:
            self.soc.sim.at(self.soc.sim.now + 1, lambda: self._capture(bits))

    def _capture(self, bits):
        self.r.hw_set("INT_STATUS", bits & self.mask)
        self.soc.update_irq()

    def irq(self):
        return (self.r.get("INT_STATUS") & self.r.get("INT_EN")) != 0
