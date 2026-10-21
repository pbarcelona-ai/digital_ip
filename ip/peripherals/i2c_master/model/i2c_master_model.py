"""i2c_master model (Python model of ip/peripherals/i2c_master/src/i2c_master.sv and its sequencer and bit
engine), event driven with the RTL's clock timing.

Registers (i2c_master_regs.json): CTRL [0] EN [1] START (command) [2] READ [3] NO_STOP, ADDR, LEN, DIV
(phase clocks - 1), STATUS [0] BUSY [1] DONE [2] NACK [3] ARB_LOST (W1C) [31:16] RX_LEVEL, IRQ_EN [0] DONE;
irq = STATUS.DONE and IRQ_EN.DONE. The write data come from the TX FIFO (its AXI-Stream slave), read data
go to the RX FIFO (its AXI-Stream master, tlast on the last byte): ip_axis_fifo models of FIFO_DEPTH.

Timing (clocks; D = DIV + 1 read when each bus command starts), as the RTL without clock stretching or a
second master:
  a CTRL write with START in clock w: the sequencer starts in clock w + 2 (BUSY from then; DONE cleared
  then if the master was idle and enabled, unless the previous transaction sets DONE in that clock),
  reading ADDR / LEN / READ / NO_STOP in clock w + 1;
  every bus command (START, STOP, a bit) takes 4 D + 2 clocks, + 2 when SCL was low before it (the
  synchroniser sees SCL rise late): every command but the first START after reset or a STOP;
  a byte is 8 bit commands and the acknowledge bit; a write byte is taken from the TX FIFO in its fetch
  clock (the first clock the FIFO shows it, at least one clock), a read byte is pushed into the RX FIFO in
  one clock after its 8 bits (or later while the FIFO is full), then the master's acknowledge (NACK after
  the last byte); after the last byte one clock, then STOP (none with NO_STOP); then one clock DONE: BUSY
  low from the clock after it, DONE / NACK set (and the interrupt) one clock later;
  the address is NACKed when no device answers it: STOP at once; EN cleared while the sequencer waits for
  a TX byte or RX space ends the transaction with a STOP and NACK (the clock after EN reads low; the
  stream handshake of that clock still happens: a read byte enters the RX FIFO, a TX byte is dropped);
  a STATUS write clears flags from the next clock (a flag set in that clock stays set).
A read needs LEN >= 1 (an address probe is a write of LEN 0: a target in read mode would drive its first
data bit against the STOP).
devices: {7-bit address: object with write(list of bytes) / read(n) -> bytes}; a read transaction reads
its bytes one at a time as they are clocked out (read(1)), a write hands over the acknowledged bytes at
its end.
The host provides sim (event queue, clocks of aclk) and update_irq()."""
from ip_axis_fifo_model import AxisFifo
from regs import RegMap, ip_regs

START, STOP, WRITE, READ = range(4)


def div_reset(clk_hz, scl_hz):
    """DIV at reset (i2c_master_regs.json DIV_RST, as i2c_top computes it): the larger of
    clk / (4 scl) and the phase that makes SCL low (2 phases) last the UM10204 tLOW minimum (4.7 us up to
    100 kHz, 1.3 us up to 400 kHz, 0.5 us above), minus 1."""
    tlow_ns = 4700 if scl_hz <= 100_000 else 1300 if scl_hz <= 400_000 else 500
    return max(clk_hz // (4 * scl_hz), (clk_hz // 1000 * tlow_ns + 1_999_999) // 2_000_000) - 1


class I2cMaster:
    """i2c_master with its register map, FIFOs and devices."""

    def __init__(self, sim, update_irq, devices, clk_hz=100_000_000, scl_hz=100_000, fifo_depth=512):
        self.sim, self.update_irq, self.dev = sim, update_irq, devices
        self.r = RegMap(ip_regs(__file__, "i2c_master"), {"DIV_RST": div_reset(clk_hz, scl_hz)})
        self.txf, self.rxf = AxisFifo(fifo_depth), AxisFifo(fifo_depth)
        self.ctrl = 0                                    # EN / READ / NO_STOP as stored (START reads 0)
        self.busy = self.done = self.nack = self.arb = False
        self.done_at = -1                                # clock DONE was last set
        self.active = False                              # the sequencer is not idle
        self.scl_low = False                             # SCL held low by the master (after a command)
        self.wait_from = None                            # clock the sequencer entered a fetch / push wait
        self.wait_kind = None                            # "tx" (a TX byte) / "rx" (RX space)
        self.gen = None
        self.tok = 0                                     # the valid resume schedule
        self.on_tx_take = None                           # host hooks: f(clock) when the sequencer takes a TX
        self.on_rx_push = None                           # byte / pushes an RX byte (the host moves words)
        self.r.sts = self._sts
        self.r.on_write = self._w

    # -- registers
    def _sts(self, name, i):
        if name == "CTRL":
            return self.ctrl
        if name == "STATUS":
            self.rxf.sync(self.sim.now)
            return (int(self.busy) | int(self.done) << 1 | int(self.nack) << 2 | int(self.arb) << 3
                    | (min(self.rxf.level(), 0xFFFF) << 16))
        return 0

    def _w(self, name, i, d):
        if name == "STATUS":                             # W1C, from the next clock
            if d & 2:
                self.done = False
            if d & 4:
                self.nack = False
            if d & 8:
                self.arb = False
            self.update_irq()
        elif name == "CTRL":
            self.sim.at(self.sim.now + 1, lambda c=d: self._ctrl(c))

    def _ctrl(self, d):
        """Clock w + 1: CTRL stored, START seen by the idle sequencer, EN low ends a wait."""
        self.ctrl = d & 0b1101
        if d & 2 and not self.active and self.ctrl & 1:
            self.active = True
            regs = (self.r.get("ADDR") & 0x7F, self.r.get("LEN"), bool(d & 4), bool(d & 8))
            self.gen = self._txn(self.sim.now + 1, *regs)
            self.sim.at(self.sim.now + 1, self._begin)
            self._resume(first=True)
        elif not self.ctrl & 1 and self.wait_from is not None and self.sim.now >= self.wait_from:
            self._resume(abort=True)

    def _begin(self):
        """The sequencer's first clock: BUSY; DONE cleared unless the previous transaction sets it in this
        clock (a set wins)."""
        self.busy = True
        if self.done_at != self.sim.now:
            self.done = False
        self.update_irq()

    def irq(self):
        return self.done and bool(self.r.get("IRQ_EN") & 1)

    # -- the streams (the host / testbench side)
    def push_tx(self, t, byte, last=0):
        """s_axis handshake in clock t; True if accepted."""
        ok = self.txf.push(t, (byte & 0xFF, last, 0))
        if ok and self.wait_kind == "tx" and self.gen is not None:
            self._schedule(self.txf.first_valid(t + 1))
        return ok

    def take_rx(self, t):
        """m_axis handshake in clock t: (byte, last) or None."""
        w = self.rxf.take(t)
        return None if w is None else (w[0], w[1])

    # -- the sequencer
    def _cmd(self, t, kind):
        """A bus command issued in clock t: the clock the sequencer's next state starts."""
        d = (self.r.get("DIV") & 0xFFFF) + 1
        nxt = t + 4 * d + 2 + (2 if self.scl_low else 0)
        self.scl_low = kind != STOP
        return nxt

    def _byte_out(self, t):
        for _ in range(8):
            t = self._cmd(t, WRITE)
        return self._cmd(t, READ)                        # the target's acknowledge

    def _schedule(self, t):
        """Resume the sequencer in clock t (a later schedule or an abort cancels this one)."""
        self.tok += 1
        k = self.tok
        self.sim.at(t, lambda: self._resume() if k == self.tok else None)

    def _resume(self, abort=False, first=False):
        """Run the sequencer until it waits for a clock or, in a fetch / push state, for the FIFO."""
        self.tok += 1                                    # cancels a pending schedule (an abort)
        try:
            what = next(self.gen) if first else self.gen.send(abort)
        except StopIteration:
            self.gen = None
            self.wait_from = self.wait_kind = None
            return
        if isinstance(what, int):
            self.wait_from = self.wait_kind = None
            self._schedule(what)
        else:                                            # ("wait", clock entered, retry clock or None, kind)
            self.wait_from, self.wait_kind = what[1], what[3]
            if what[2] is not None:
                self._schedule(what[2])

    def _txn(self, t, addr, n, rd, nostop):
        """The transaction; t is its first clock (START_I). Yields the clock to continue at, or ("wait",
        entered, retry) in a fetch / push state; send(True) there aborts (EN low): STOP from the next clock,
        NACK reported."""
        nack, stop_at = False, None
        t = self._cmd(t, START)
        t = self._byte_out(t)                            # address + R/W: acknowledged?
        dev = self.dev.get(addr)
        if dev is None:
            nack, stop_at = True, t                      # NACK: STOP at once
        elif n and rd:
            for k in range(n):
                byte = dev.read(1)[0]                    # the device sends the byte (its pointer moves)
                for _ in range(8):
                    t = self._cmd(t, READ)
                abort = yield t                          # RPUSH: a clock with space in the RX FIFO
                while True:
                    now = self.sim.now
                    self.rxf.sync(now)
                    pushed = not self.rxf.full()             # the handshake of this clock, abort or not
                    if pushed:
                        self.rxf.push(now, (byte & 0xFF, int(k == n - 1), 0))
                        if self.on_rx_push:
                            self.on_rx_push(now)
                    if abort or not self.ctrl & 1:
                        nack, stop_at = True, now + 1
                        break
                    if pushed:
                        break
                    abort = yield ("wait", t, now + 1, "rx")
                if nack:
                    break
                t = self._cmd(self.sim.now + 1, WRITE)  # the master's ACK / NACK
        elif n:
            sent = []
            for k in range(n):
                abort = yield t                          # WFETCH: the first clock the TX FIFO shows a byte
                while True:
                    now = self.sim.now
                    v = self.txf.first_valid(now)
                    if abort or not self.ctrl & 1:
                        if v == now:
                            self.txf.take(now)                   # the handshake of this clock: dropped
                        nack, stop_at = True, now + 1
                        break
                    if v == now:
                        sent.append(self.txf.take(now)[0])
                        if self.on_tx_take:
                            self.on_tx_take(now)
                        break
                    abort = yield ("wait", t, v, "tx")  # v None: until a byte is pushed
                if nack:
                    break
                t = self._byte_out(self.sim.now + 1)
            dev.write(sent)
        if stop_at is None:
            t += 1                                       # END (one clock), then STOP unless NO_STOP
            if not nostop:
                t = self._cmd(t, STOP)
        else:
            t = self._cmd(stop_at, STOP)
        yield t                                          # DONE in clock t
        self.sim.at(t + 1, self._idle)
        self.sim.at(t + 2, lambda: self._finish(nack))

    def _idle(self):
        self.busy = False
        self.active = False
        self.update_irq()

    def _finish(self, nack):
        self.done = True
        self.done_at = self.sim.now
        self.nack = self.nack or nack
        self.update_irq()
