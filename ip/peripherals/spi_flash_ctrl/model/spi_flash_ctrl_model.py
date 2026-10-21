"""spi_flash_ctrl model (Python model of ip/peripherals/spi_flash_ctrl/src/spi_flash_ctrl.sv), event driven with
the RTL's clock timing and pins, and the board's SPI NOR flash (FlashMem).

Registers (spi_flash_ctrl_regs.json): CMD (write: [7:0] opcode [8] address [15:12] dummy bytes [16] read data
[17] write data; ignored with CMD_ERR while busy), ADDR (24 bits), LEN (data bytes), CLKDIV (SCLK half period,
below 3 acts as 3), STATUS [0] BUSY [1] DONE [2] CMD_ERR (W1C, a set in the same clock wins), IRQ_EN [0];
irq = DONE and IRQ_EN. Write data come on the AXI-Stream slave (taken only in a write-wait clock: tready is
that state), read data leave on the AXI-Stream master through a one-word output register (OutReg).

Timing (clocks; H = max(3, CLKDIV)): a CMD write in clock w while idle: BUSY and CS_N low from w + 1, DONE
cleared then; after H clocks the bytes, each from a load clock t: a byte shifts in 16 H clocks from t + 1
(SCLK rises at t + H + 2 k H, MISO sampled there as it was 2 clocks before; SCLK falls H later and MOSI moves
to the next bit; MOSI = the byte's MSB from t + 1); opcode, 3 address bytes (MSB first), dummy bytes (0x00),
then LEN data bytes (MOSI 0x00 when reading; a write byte waits in a clock with the stream offering one, its
shift starting the clock after); a read byte goes to the output register in the first clock it is free
after the shift (valid from the clock after), the next byte loading then; after the last byte CS hold for H
clocks, CS_N high for 2 H clocks, then idle: BUSY low and DONE set in that clock. CMD_ERR the clock after a
CMD write while busy. CLKDIV is taken when a command starts (the RTL compares it live: change it only between
commands).
MISO: miso_source(n) (a function of the clock), else the flash device: device.data(opcode, addr, n_bytes)
returns the data bytes a read command shifts out (byte level: the flash changes MISO after SCLK falls, H >= 3
lets the synchroniser see the bit at the next rising edge).
Hooks for a host: on_tx_ready(t) (a write-wait clock begins), on_rx_push(t). sim: event queue (aclk)."""
from regs import RegMap, ip_regs


class FlashMem:
    """The board's SPI NOR flash: the boot image (erased bytes 0xFF after it), JEDEC ID EF 40 17 (9Fh), reads
    03h / 0Bh."""

    def __init__(self, image, size=0x10000):
        self.mem = bytearray(image) + bytearray(b"\xff" * max(0, size - len(image)))

    def data(self, op, addr, n):
        if op == 0x9F:
            return ([0xEF, 0x40, 0x17] + [0] * n)[:n]
        if op in (0x03, 0x0B):
            return [self.mem[(addr + k) % len(self.mem)] for k in range(n)]
        return [0xFF] * n


class Line:
    """A pin as its transitions (clock, level)."""

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


class OutReg:
    """The controller's read-data output register (m_axis): a word pushed in clock c is valid from c + 1; a
    take (tready while valid) in clock h frees it from h + 1. FIFO-like methods for a host's stream glue."""

    def __init__(self):
        self.word, self.valid_from, self.t = None, 0, 0

    def sync(self, t):
        self.t = max(self.t, t)

    def tvalid(self, t=None):
        t = self.t if t is None else t
        return self.word is not None and t >= self.valid_from

    def full(self):
        return self.word is not None

    def push(self, c, word):
        self.word, self.valid_from = word, c + 1

    def take(self, t):
        if not self.tvalid(t):
            return None
        w, self.word = self.word, None
        self.free_from = t + 1
        return w

    def first_valid(self, t):
        if self.word is None:
            return None
        return max(t, self.valid_from)


class FlashCore:
    """spi_flash_ctrl: registers, the command sequencer, the output register and the pins."""

    def __init__(self, sim, update_irq, device=None):
        self.sim, self.update_irq, self.device = sim, update_irq, device
        self.r = RegMap(ip_regs(__file__, "spi_flash_ctrl"))
        self.out = OutReg()
        self.rxf = self.out                              # the host glue's name for the read stream
        self.sclk, self.mosi, self.cs_n = Line(0), Line(0), Line(1)
        self.miso_source = None
        self.busy = self.done = self.err = False
        self.idle_from = 0                               # first clock the sequencer is idle (accepts CMD)
        self.wtx = None                                  # (clock entered, continuation) while waiting for a byte
        self.out_free = 0                                # first clock the output register is free
        self.on_tx_ready = self.on_rx_push = None
        self.r.sts = self._sts
        self.r.on_write = self._w

    def _sts(self, name, i):
        if name == "STATUS":
            return int(self.busy) | int(self.done) << 1 | int(self.err) << 2
        return 0

    def irq(self):
        return self.done and bool(self.r.get("IRQ_EN") & 1)

    def _w(self, name, i, d):
        now = self.sim.now
        if name == "STATUS":
            if d & 2:
                self.done = False
            if d & 4:
                self.err = False
            self.update_irq()
        elif name == "CMD":
            if now < self.idle_from:
                self.sim.at(now + 1, self._cmd_err)
            else:
                self._start(now, d)

    def _cmd_err(self):
        self.err = True
        self.update_irq()

    # -- streams (host side)
    def push_tx(self, t, byte, last=0):
        """s_axis handshake in clock t: accepted only in a write-wait clock."""
        if self.wtx is None or t < self.wtx[0]:
            return False
        cont, self.wtx = self.wtx[1], None
        cont(t, byte & 0xFF)
        return True

    def take_rx(self, t):
        w = self.out.take(t)
        if w is not None:
            self.out_free = t + 1
            if self.wrx is not None:
                c = self.wrx
                self.wrx = None
                self.sim.at(t + 1, lambda: c(t + 1))
        return None if w is None else (w[0], w[1])

    wrx = None

    def miso_at(self, n):
        return self.miso_source(n) if self.miso_source else 0

    # -- the sequencer
    def _start(self, w, d):
        h = max(3, self.r.get("CLKDIV") & 0xFFFF)
        op, n = d & 0xFF, self.r.get("LEN") & 0xFFFF
        addr = self.r.get("ADDR") & 0xFFFFFF
        rd, wr = (d >> 16) & 1, (d >> 17) & 1
        tx = [op] + ([(addr >> s) & 0xFF for s in (16, 8, 0)] if d & 0x100 else []) + [0] * ((d >> 12) & 15)
        self.idle_from = 1 << 62                         # engaged until the command ends
        self.sim.at(w + 1, self._begin)
        self.cs_n.set(w + 1, 0)
        dev = list(self.device.data(op, addr, n)) if (self.device and rd and not self.miso_source) else None
        self.seq = dict(h=h, tx=tx, n=n, rd=rd, wr=wr, dev=dev, k=0)
        self._load(w + h + 1)

    def _begin(self):
        self.busy = True
        self.done = False
        self.update_irq()

    def _load(self, t):
        """The load clock t: the next byte, or the end of the command."""
        s = self.seq
        if s["tx"]:
            self._shift(t, s["tx"].pop(0), False, None)
        elif s["n"]:
            s["n"] -= 1
            last = int(s["n"] == 0)
            if s["wr"]:
                self.wtx = (t + 1, lambda c, b: self._shift(c, b, s["rd"], last))
                if self.on_tx_ready:
                    self.sim.at(t + 1, lambda: self.on_tx_ready(t + 1))
            else:
                self._shift(t, 0, s["rd"], last)
        else:
            h = s["h"]
            self.cs_n.set(t + 1 + h, 1)                  # CS hold, then the gap with CS_N high
            end = t + 1 + 3 * h
            self.idle_from = end
            self.sim.at(end, self._end)

    def _shift(self, t, byte, is_rx, last):
        """A byte loaded in clock t (shift from t + 1): pins, samples, the next step at t + 1 + 16 H."""
        h = self.seq["h"]
        s0 = t + 1
        self.mosi.set(s0, (byte >> 7) & 1)
        samples = []
        for k in range(8):
            r = s0 + 2 * k * h + h - 1                   # rising edge: sample
            self.sclk.set(r + 1, 1)
            samples.append(r - 2)
            f = r + h                                     # falling edge: shift
            self.sclk.set(f + 1, 0)
            self.mosi.set(f + 1, (byte >> (6 - k)) & 1 if k < 7 else 0)
        nxt = s0 + 16 * h
        if is_rx:
            self.sim.at(nxt, lambda: self._wrx(nxt, samples, last))
        else:
            self.sim.at(nxt, lambda: self._load(nxt))

    def _wrx(self, c, samples, last):
        """The write-to-output state: the byte into the output register when it is free."""
        s = self.seq
        if s["dev"] is not None:
            byte = s["dev"][s["k"]]
        else:
            byte = 0
            for n in samples:
                byte = (byte << 1) | self.miso_at(n)
        if self.out.word is not None:                    # not taken yet: retry when it is
            self.wrx = lambda cc: self._wrx(cc, samples, last)
            return
        s["k"] += 1
        self.out.push(c, (byte, last, 0))
        if self.on_rx_push:
            self.on_rx_push(c)
        self.sim.at(c + 1, lambda: self._load(c + 1))

    def _end(self):
        self.busy = False
        self.done = True
        self.update_irq()
