"""py_boot model (Python model of ip/cpu/py_soc/src/py_boot.sv) with the RTL's clock timing: the flash boot
loader as the bus master of the soc model.

Sequence: CLKDIV, ADDR (BOOT_ADDR), LEN 12, CMD (03h read) of spi_flash_ctrl; the 12-byte header polled
from the flash data port's RXDATA (bit 31 valid, [7:0] the byte); the header checked (magic "PYC1", code
length 1..2**CODE_AW, constant count 0..2**CONST_AW); ADDR (BOOT_ADDR + 12), LEN (the payload), CMD; the
payload polled the same way (code bytes, then each constant as 5 bytes, [33:0] used); the 32-bit sum of the
payload compared. Errors (err_code): 1 bad magic, 2 sizes out of range, 3 checksum, 4 bus error (a response
other than OKAY), 5 no flash data for 65536 consecutive polls.

Timing (clocks from the release of reset, clock t0): one bus operation at a time; an operation issued in
clock i raises VALID in i + 1 (V), acts in V + effect (the crossbar's timing, py_axil_xbar_model) and has its
response handshake in V + response; op_done is the clock after. A write state moves on in the op_done
clock and the next state issues its write the clock after; a poll is processed in its op_done clock and
the next poll issued in that clock. After the last header byte the header is checked in the clock after
op_done and the second command's ADDR issued the clock after that; after the last payload byte the sum is
checked in the clock after op_done and done_o (or err_o) is high from the clock after that. An error
(bus, no data) moves to err_o in the clock after op_done.
run(t0) works like the core model: it advances the event queue to each access's clock (every hardware
event up to that clock is processed first) and then makes the access on the soc: sim (event queue),
timing(addr, write), read(addr) -> (data, ok), write(addr, data) -> ok. It returns when done_o or err_o
rises (in clock `at`, sim.now = at); py_soc starts the core in the clock after."""

MAGIC = 0x3143_5950
CMD_READ = 0x0001_0103
HDR_BYTES = 12
F_CMD, F_ADDR, F_LEN, F_DIV = 0x10, 0x14, 0x18, 0x1C
P_RX = 0x14


class _Stop(Exception):
    pass


class PyBoot:
    """py_boot: the boot sequence, its bus operations and the loaded code / constants."""

    def __init__(self, soc, flash_regs=0xC000, flash_port=0xC100, boot_addr=0, clkdiv=3, code_aw=15,
                 const_aw=8):
        self.soc, self.sim = soc, soc.sim
        self.fr, self.fp = flash_regs, flash_port
        self.boot_addr, self.clkdiv = boot_addr, clkdiv
        self.code_aw, self.const_aw = code_aw, const_aw
        self.code, self.consts = bytearray(), []
        self.done = self.err = False
        self.err_code = 0
        self.at = None                                   # clock done_o / err_o rose

    def run(self, t0=0):
        """The boot from clock t0 (the first clock after reset); True when the image was loaded."""
        try:
            t = t0
            for a, d in ((F_DIV, self.clkdiv), (F_ADDR, self.boot_addr), (F_LEN, HDR_BYTES), (F_CMD, CMD_READ)):
                t = self._write(t, a, d)
            hdr = []
            t = self._poll(t, HDR_BYTES, hdr.append)
            payload = self._check(t + 1, hdr)
            t += 2
            for a, d in ((F_ADDR, self.boot_addr + HDR_BYTES), (F_LEN, payload), (F_CMD, CMD_READ)):
                t = self._write(t, a, d)
            self.sum, self.cbuf = 0, []
            t = self._poll(t, payload, self._payload_byte)
            self._finish(t + 2, 0 if self.sum & 0xFFFFFFFF == self.hdr_sum else 3)
        except _Stop:
            pass
        return self.done

    def _to(self, t):
        if t > self.sim.now:
            self.sim.advance(t - self.sim.now)

    def _op(self, i, write, addr, data=0):
        """An operation issued in clock i: (op_done clock, data, ok)."""
        eff, resp = self.soc.timing(addr, write)
        self._to(i + 1 + eff)
        if write:
            d, ok = 0, self.soc.write(addr, data & 0xFFFFFFFF)
        else:
            d, ok = self.soc.read(addr)
        done = i + 1 + resp + 1
        if not ok:
            self._finish(done + 1, 4)
        return done, d

    def _write(self, i, off, d):
        """A write state from clock i: the next state's first clock."""
        done, _ = self._op(i, True, self.fr + off, d)
        return done + 1

    def _poll(self, i, n, take):
        """Polls RXDATA from clock i until n bytes arrived: the op_done clock of the last one."""
        got = polls = 0
        while True:
            done, d = self._op(i, False, self.fp + P_RX)
            if d >> 31 & 1:
                take(d & 0xFF)
                got += 1
                polls = 0
                if got == n:
                    return done
            elif polls == 0xFFFF:
                self._finish(done + 1, 5)
            else:
                polls += 1
            i = done

    def _check(self, t, h):
        """S_CHECK in clock t: the payload length, or err_o from t + 1."""
        magic = int.from_bytes(bytes(h[0:4]), "little")
        self.code_len = h[4] | h[5] << 8
        n_const = h[6] | h[7] << 8
        self.hdr_sum = int.from_bytes(bytes(h[8:12]), "little")
        if magic != MAGIC:
            self._finish(t + 1, 1)
        if self.code_len == 0 or self.code_len > 1 << self.code_aw or n_const > 1 << self.const_aw:
            self._finish(t + 1, 2)
        return (self.code_len + n_const * 5) & 0xFFFF

    def _payload_byte(self, b):
        self.sum += b
        if len(self.code) < self.code_len:
            self.code.append(b)
        else:
            self.cbuf.append(b)
            if len(self.cbuf) == 5:
                self.consts.append(int.from_bytes(bytes(self.cbuf[:4]), "little") | (self.cbuf[4] & 3) << 32)
                self.cbuf = []

    def _finish(self, t, code):
        """done_o (code 0) or err_o with err_code from clock t."""
        self._to(t)
        self.done, self.err, self.err_code, self.at = code == 0, code != 0, code, t
        if code:
            raise _Stop()
