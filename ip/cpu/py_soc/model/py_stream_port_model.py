"""py_stream_port model (Python model of ip/cpu/py_soc/src/py_stream_port.sv): a peripheral's data port with
a TX FIFO towards the peripheral and an RX FIFO from it (ip_axis_fifo models, DEPTH + 2 words each), clock
accurate:
  TXDATA (write): [DATA_W-1:0] data, [24] tlast into the TX FIFO in the clock of the write, or dropped with
                  STATUS.TX_OVF set when it is full;
  RXDATA (read):  [31] valid, [24] tlast, [DATA_W-1:0] data of the RX FIFO's output in the clock of the
                  read, which pops it when valid;
  STATUS:         [0] rx_valid [1] tx_ready (not full) [2] tx_ovf (write 1 to clear) [3] tx_empty
                  [19:8] RX level [31:20] TX level;
  IRQ_EN:         [0] rx_valid [1] tx_ready [2] tx_empty; irq() is the condition of the current clock (the
                  RTL registers it: irq_o follows one clock later).
The peripheral side: take_tx(t) is the m_axis handshake of clock t (the peripheral's tready), push_rx(t, word)
the s_axis one (accepted unless the RX FIFO is full). Hooks: on_tx(t) after a word entered the TX FIFO,
on_rx_pop(t) after the CPU took an RX word (space for the peripheral).
sim is the event queue (clocks of aclk). After every FIFO handshake of clock t an (empty) event is scheduled
in each of the next 3 clocks, while the FIFO pipeline moves: a host evaluating irq() after every event sees
each change of the condition in its clock."""
from ip_axis_fifo_model import AxisFifo
from regs import RegMap, ip_regs


class StreamPort:
    """py_stream_port: registers, TX and RX FIFOs."""

    def __init__(self, sim, tx_depth=16, rx_depth=16, data_w=8, on_tx=None):
        self.sim = sim
        self.r = RegMap(ip_regs(__file__, "py_stream_port"))
        self.txf, self.rxf = AxisFifo(tx_depth), AxisFifo(rx_depth)
        self.mask = (1 << data_w) - 1
        self.tx_ovf = False
        self.on_tx = on_tx
        self.on_rx_pop = None
        self.r.sts = self._sts
        self.r.on_write = self._w
        self.r.on_read = self._rd
        self.settle_at = -1                             # last clock with a settle event scheduled

    def _settle(self, t):
        for c in range(max(t + 1, self.settle_at + 1), t + 4):
            self.sim.at(c, lambda: None)
        self.settle_at = max(self.settle_at, t + 3)

    def _status(self):
        now = self.sim.now
        self.txf.sync(now)
        self.rxf.sync(now)
        tl, rl = self.txf.level(), self.rxf.level()
        return ((tl & 0xFFF) << 20 | (rl & 0xFFF) << 8 | int(tl == 0) << 3 | int(self.tx_ovf) << 2
                | int(not self.txf.full()) << 1 | int(self.rxf.tvalid()))

    def _sts(self, name, i):
        if name == "RXDATA":
            self.rxf.sync(self.sim.now)
            if self.rxf.tvalid():
                d, last, _ = self.rxf.o_q
                return (1 << 31) | (last << 24) | (d & self.mask)
            return 0
        if name == "STATUS":
            return self._status()
        return 0

    def _rd(self, name, i):
        if name == "RXDATA" and self.rxf.tvalid():               # the read pops a valid word
            self.rxf.take(self.sim.now)
            self._settle(self.sim.now)
            if self.on_rx_pop:
                self.on_rx_pop(self.sim.now)

    def _w(self, name, i, d):
        now = self.sim.now
        if name == "TXDATA":
            self.txf.sync(now)
            if self.txf.full():
                self.tx_ovf = True
            else:
                self.txf.push(now, (d & self.mask, (d >> 24) & 1, 0))
                self._settle(now)
                if self.on_tx:
                    self.on_tx(now)
        elif name == "STATUS" and d & 4:
            self.tx_ovf = False

    # -- the peripheral side
    def take_tx(self, t):
        """m_axis handshake in clock t: (data, last) or None."""
        w = self.txf.take(t)
        if w is not None:
            self._settle(t)
        return None if w is None else (w[0], w[1])

    def push_rx(self, t, d, last=0):
        """s_axis handshake in clock t: True if accepted (the RX FIFO not full)."""
        ok = self.rxf.push(t, (d & self.mask, last & 1, 0))
        if ok:
            self._settle(t)
        return ok

    def irq(self):
        """The interrupt condition of the current clock (irq_o one clock later)."""
        en = self.r.get("IRQ_EN") & 7
        if not en:
            return False
        now = self.sim.now
        if en & 1:
            self.rxf.sync(now)
            if self.rxf.tvalid():
                return True
        if en & 6:
            self.txf.sync(now)
            return bool((en & 2 and not self.txf.full()) or (en & 4 and self.txf.level() == 0))
        return False
