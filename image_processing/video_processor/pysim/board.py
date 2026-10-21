"""Board models of tb/video_processor_tb.sv: camera control interface (CCI register model at 0x36 on
I2C 0), I2C EEPROM (0x50 on I2C 1), GPIO straps and loopbacks, and the transcript (UART 0 text, or the
GPIO1 direct transcript port).

Camera control registers (8-bit index, auto-increment; the CCI byte order is high byte first):
  0x01 stream on (1)            0x10-0x1F scratch (self-test)      0x20-0x21 frame gap, ns
  0x30-0x33 frame width, height 0x40-0x4F image name (ASCII, 0 ends it)
  0x50 classes to detect (bit c)                                    0x51-0x55 box style of class 0-4
  0x56 tracking sequences the camera will send                      0x57 number of the sequence loaded
  0x58 most targets tracked at a time (1-32, 0 = 32)
GPIO0 inputs: [31] quick strap, [30] image format (1 monochrome), [29] image sequence running,
[28] direct transcript strap. GPIO0 outputs: [0] camera out of reset, [1] run LED, [2] monochrome LED.
"""


class RegDevice:
    """An I2C register device: a write sets the index (first byte) and stores the rest; a read returns
    bytes from the index on, auto-incrementing."""

    def __init__(self, size=256):
        self.mem = bytearray(size)
        self.ptr = 0
        self.on_write = lambda reg, value: None

    def write(self, data):
        if not data:
            return
        self.ptr = data[0] % len(self.mem)
        for b in data[1:]:
            self.mem[self.ptr] = b
            self.on_write(self.ptr, b)
            self.ptr = (self.ptr + 1) % len(self.mem)

    def read(self, n):
        out = []
        for _ in range(n):
            out.append(self.mem[self.ptr])
            self.ptr = (self.ptr + 1) % len(self.mem)
        return out


class Camera(RegDevice):
    """Sensor CCI register model; the frame source is driven by the testbench (sim.py)."""

    def __init__(self):
        super().__init__()
        self.mem[0x20], self.mem[0x21] = 0x05, 0x00                    # frame gap 1280 ns (power-on)

    def set16(self, reg, v):
        self.mem[reg], self.mem[reg + 1] = (v >> 8) & 0xFF, v & 0xFF

    def get16(self, reg):
        return (self.mem[reg] << 8) | self.mem[reg + 1]

    def load(self, w, h, name, det_mask, styles, max_targets, seqs, seq_no):
        """Settings of one tracking sequence (the testbench's start-up load)."""
        self.set16(0x30, w)
        self.set16(0x32, h)
        nb = name.encode("ascii", "replace")[:16]
        self.mem[0x40:0x50] = nb + bytes(16 - len(nb))
        self.mem[0x50] = det_mask
        for c, s in enumerate(styles):
            self.mem[0x51 + c] = s
        self.mem[0x58] = max_targets % 256
        if len(styles) <= 4:                         # 4-class firmware: most targets in register 0x55
            self.mem[0x55] = max_targets % 256
        self.mem[0x56] = seqs
        self.mem[0x57] = seq_no

    def streaming(self):
        return self.mem[0x01] & 1


class Board:
    def __init__(self, quick=True, direct=False, transcript=None):
        self.camera = Camera()
        self.eeprom = RegDevice()
        self.quick, self.direct = quick, direct
        self.mono = False
        self.seq_active = False
        self.cam_reset_n = 0
        self.lines = []
        self._line = []
        self.transcript = transcript                 # open text file or None
        self.echo = None                             # function(line) or None
        self._tport_tog = None

    # -- GPIO
    def gpio0_in(self, out, drive):
        return ((int(self.quick) << 31) | (int(self.mono) << 30) | (int(self.seq_active) << 29)
                | (int(self.direct) << 28))

    def gpio0_out(self, v):
        self.cam_reset_n = v & 1

    def gpio1_in(self, out, drive):
        return 0

    def gpio1_out(self, v):
        """Direct transcript port: [31:24] 0xDB, [8] toggles per character, [7:0] the character."""
        if (v >> 24) & 0xFF == 0xDB:
            tog = (v >> 8) & 1
            if tog != self._tport_tog:
                self._tport_tog = tog
                self._char(v & 0xFF)

    # -- transcript
    def uart0_char(self, c):
        if not self.direct:
            self._char(c)

    def _char(self, c):
        if c == 10:
            line = bytes(self._line).decode("latin-1").rstrip("\r")
            self._line = []
            self.lines.append(line)
            if self.transcript:
                self.transcript.write(line + "\n")
                self.transcript.flush()
            if self.echo:
                self.echo(line)
        elif c != 13:
            self._line.append(c)
