"""py_axil_xbar model (Python model of ip/cpu/py_soc/src/py_axil_xbar.sv in py_soc): the address decode of
py_soc_map_pkg.sv and the clock timing of one access through the crossbar to each kind of slave.

Decode (decode(addr) -> (kind, window, offset)): the 256-byte register windows (WIN, the data port of a
streaming peripheral at +0x100: DPORT) -> "regs"; RAM_BASE 64 KB -> "ram"; the external windows EXT (64 KB)
and DDR (64 MB) when enabled -> "ext" / "ddr"; anything else -> "err" (DECERR from the crossbar).

Timing (timing(kind) -> (effect, response), clocks from the clock V the master raises AWVALID + WVALID or
ARVALID; the crossbar latches the decoded slave in V and forwards from V + 1):
  "regs"  a register map (axi4_lite_slave, READ_WAIT 0, and the generated <ip>_regs): AW / W or AR taken
          in V + 1; the write's strobe (cfg_*_wr, the new register value) in V + 4; the read's value
          sampled (an RC register's read pulse) in V + 4; the response handshake in V + 5 -> (4, 5);
  "ram"   py_data_ram: taken, written / read in V + 1, response handshake in V + 2 -> (1, 2);
  "err"   DECERR: AW / W or AR taken in V + 1, response handshake in V + 2 -> (1, 2) (no slave acts);
  "ext" / "ddr"  the window object's timing(offset, write) if it has one, else (1, 2): a slave with READY
          high and the response the clock after (py_data_ram's timing).
Masters: py_core raises VALID 3 clocks after an instruction starts and starts the next one the clock after
the response (py_core_model PyCore with bus.timing); py_boot raises it the clock after it issues
(py_boot_model)."""

WIN_MASK, DPORT = 0xFFFF_FF00, 0x100
RAM_BASE, RAM_BYTES = 0x0004_0000, 0x1_0000
EXT_BASE, EXT_BYTES = 0x0001_0000, 0x1_0000
DDR_BASE, DDR_BYTES = 0x1000_0000, 0x0400_0000
TIMING = {"regs": (4, 5), "ram": (1, 2), "err": (1, 2)}


class Xbar:
    """The decode and timing. windows: {base: register map (RegMap-like: read(off) / write(off, d))} with
    ports {base: data port register map} at base + DPORT; ext / ddr: window objects or None (not decoded)."""

    def __init__(self, windows, ports, ext_en=True, ddr_en=True):
        self.windows, self.ports = windows, ports
        self.ext_en, self.ddr_en = ext_en, ddr_en
        self.ext = self.ddr = None

    def decode(self, addr):
        if RAM_BASE <= addr < RAM_BASE + RAM_BYTES:
            return "ram", None, addr - RAM_BASE
        if self.ext_en and EXT_BASE <= addr < EXT_BASE + EXT_BYTES:
            return "ext", self.ext, addr - EXT_BASE
        if self.ddr_en and DDR_BASE <= addr < DDR_BASE + DDR_BYTES:
            return "ddr", self.ddr, addr - DDR_BASE
        win = addr & WIN_MASK
        if win in self.windows:
            return "regs", self.windows[win], addr & 0xFF
        if win - DPORT in self.ports:
            return "regs", self.ports[win - DPORT], addr & 0xFF
        return "err", None, 0

    def timing(self, addr, write):
        kind, tgt, off = self.decode(addr)
        if kind in ("ext", "ddr"):
            f = getattr(tgt, "timing", None)
            return f(off, write) if f else TIMING["ram"]
        return TIMING[kind]
