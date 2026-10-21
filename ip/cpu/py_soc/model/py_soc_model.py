"""py_soc model (Python model of ip/cpu/py_soc/src/py_soc.sv): the address map of py_soc_map_pkg.sv, the
crossbar (py_axil_xbar_model: decode and the clock timing of each access), the boot loader (py_boot_model),
the interrupt sources and the peripherals, each from its own IP model:

  0x0100 SYSCTL  py_sysctl_model      0x1000 INTC   intc_model (17 sources)    0x2000 WDT  watchdog_model
  0x3000-0x5000 GPIO 0-2  gpio_model  0x6000-0x7000 UART 0-1  uart_model (115200 baud)
  0x8000-0x9000 I2C 0-1  i2c_master_model (400 / 100 kHz; camera CCI 0x36, EEPROM 0x50)
  0xA000-0xB000 SPI 0-1  spi_master_model                     0xC000 FLASH  spi_flash_ctrl_model
  data ports (py_stream_port_model) at +0x100; 0x1_0000-0x1_FFFF the external window (the design's video
  system, `ext`: read(off) -> (data, resp) / write(off, data) -> resp, optional timing(off, write)); 0x4_0000
  the 64 KB data RAM (py_data_ram: the firmware's arrays; a word never written reads 0 here, the RTL's is
  undefined: firmware writes before it reads); 0x1000_0000 the CPU's 64 MB window onto DDR (`ddr`:
  word(off) / set_word(off, d), optional timing(off, write); the NPU's program and results); interrupt
  sources as py_soc.sv (17: 16 is the SYSCTL timer; I2Cn's is its data port's OR its done interrupt).

Time is counted in CPU clock cycles (the event queue `sim`, CPU_HZ); clock 0 is the first clock after the
system reset. The core (py_core_model PyCore) uses the Soc as its bus: read / write / timing (the crossbar's,
so every access acts in the RTL's clock) / tick / irq / budget. boot() runs the flash boot loader from clock
0 (its accesses go through the same bus) and returns with sim.now at the clock done_o (or err_o) rose; py_soc
starts the core in the clock after, with the loaded code and constants (boot_code / boot_consts).

The board (tb models) supplies: gpio<n>_in(out, drive) / gpio<n>_out(v) (n = 0..2, optional), uart0_char(c),
i2c_devices(n) ({address: device}; default camera 0x36 on I2C0, eeprom 0x50 on I2C1). cfg (dict, defaults:
video_processor's py_soc): uart_baud (UART0, UART1), i2c_hz, spi_hz, gpio_loopback (per bank: driven pins
read their own output), uart_cross (UART0 TXD -> UART1 RXD and back; else each looped to itself), nclk /
clk_en_rst / clkgen (SYSCTL CLK_EN, CLK_STATUS), ext_en / ddr_en (the windows decoded), port_depth (data port FIFOs), boot_addr,
flash_clkdiv, code_aw.
"""
from gpio_model import Gpio
from i2c_master_model import I2cMaster
from intc_model import Intc
from py_axil_xbar_model import RAM_BYTES, Xbar
from py_boot_model import PyBoot
from py_stream_port_model import StreamPort
from py_sysctl_model import SysCtl
from spi_flash_ctrl_model import FlashCore, FlashMem
from spi_master_model import SpiCore
from uart_model import UartCore
from watchdog_model import Wdt

IP_FIFO = 2                                          # py_soc.sv: the stream FIFOs inside each peripheral
CFG = dict(uart_baud=(115_200, 115_200), i2c_hz=(400_000, 100_000), spi_hz=(10_000_000, 10_000_000),
           gpio_loopback=(False, True, True), uart_cross=False, nclk=4, clk_en_rst=0, clkgen=True, ext_en=True, ddr_en=True,
           port_depth=16, boot_addr=0, flash_clkdiv=3, code_aw=15)


class PortLink:
    """The streams between a peripheral core (its FIFOs of IP_FIFO words: push_tx / take_rx / txf / rxf and
    hooks on_tx_take / on_rx_push) and its data port (py_stream_port, the deep FIFOs): a word moves in the
    clock the sending FIFO shows it and the receiving one has room (transaction level; py_soc's exact stream
    timing is compared when py_soc is)."""

    def __init__(self, sim, core, port):
        self.sim, self.core, self.port = sim, core, port
        port.on_tx = self._tx_kick
        port.on_rx_pop = lambda t: self.sim.at(t + 1, self._rx_move)
        core.on_tx_take = lambda t: self.sim.at(t + 1, self._tx_move)
        core.on_rx_push = lambda t: self.sim.at(core.rxf.first_valid(t + 1), self._rx_move)

    def _tx_kick(self, t):
        v = self.port.txf.first_valid(t)
        if v is not None:
            self.sim.at(v, self._tx_move)

    def _tx_move(self):
        now = self.sim.now
        if self.port.txf.first_valid(now) != now:
            return
        self.core.txf.sync(now)
        if self.core.txf.full():
            return                                       # the core's next take moves it (on_tx_take)
        d, last = self.port.take_tx(now)
        self.core.push_tx(now, d, last)
        v = self.port.txf.first_valid(now + 1)
        if v is not None:
            self.sim.at(v, self._tx_move)

    def _rx_move(self):
        now = self.sim.now
        if self.core.rxf.first_valid(now) != now:
            return
        self.port.rxf.sync(now)
        if self.port.rxf.full():
            return                                       # the CPU's next pop moves it (on_rx_pop)
        d, last = self.core.take_rx(now)
        self.port.push_rx(now, d, last)
        v = self.core.rxf.first_valid(now + 1)
        if v is not None:
            self.sim.at(v, self._rx_move)


class I2cPort:
    """An I2C bus of py_soc: i2c_master (IP_FIFO-word FIFOs, the instance's bus rate) and its data port.
    irq(): the done interrupt OR the port's."""

    def __init__(self, soc, hz, devices, depth=16):
        self.core = I2cMaster(soc.sim, soc.update_irq, devices, soc.sim.hz, hz, IP_FIFO)
        self.port = StreamPort(soc.sim, depth, depth, 8)
        self.link = PortLink(soc.sim, self.core, self.port)
        self.r = self.core.r

    def irq(self):
        return self.core.irq() or self.port.irq()


class UartPort:
    """A UART of py_soc: uart (IP_FIFO-word FIFOs, the baud rate, TXD looped back to RXD on the board) and its
    data port; on_char(c) at every transmitted character (the transcript)."""

    def __init__(self, soc, baud, depth=16, on_char=None):
        self.core = UartCore(soc.sim, soc.update_irq, soc.sim.hz, baud, IP_FIFO)
        self.core.on_char = on_char
        self.port = StreamPort(soc.sim, depth, depth, 8)
        self.link = PortLink(soc.sim, self.core, self.port)
        self.r = self.core.r


class SpiPort:
    """An SPI master of py_soc: spi_master (16-bit words, 2 chip selects, the SCLK rate, IP_FIFO-word FIFOs,
    MOSI looped back to MISO on the board) and its data port."""

    def __init__(self, soc, sclk_hz=10_000_000, depth=16):
        self.core = SpiCore(soc.sim, soc.update_irq, soc.sim.hz, sclk_hz, 16, 2, IP_FIFO)
        self.port = StreamPort(soc.sim, depth, depth, 16)
        self.link = PortLink(soc.sim, self.core, self.port)
        self.r = self.core.r


class FlashPort:
    """py_soc's boot flash interface: spi_flash_ctrl with the board's SPI NOR flash (FlashMem) and its data
    port. Read bytes move from the controller's output register into the port when it has room; a write byte
    moves in a write-wait clock of the controller when the port shows one. irq(): the done interrupt."""

    def __init__(self, soc, image, depth=16):
        self.sim = soc.sim
        self.core = FlashCore(soc.sim, soc.update_irq, FlashMem(image))
        self.port = StreamPort(soc.sim, depth, depth, 8, on_tx=self._tx_try)
        self.r = self.core.r
        self.core.on_tx_ready = self._tx_try
        self.core.on_rx_push = lambda t: self.sim.at(self.core.out.first_valid(t + 1), self._rx_move)
        self.port.on_rx_pop = lambda t: self.sim.at(t + 1, self._rx_move)

    def _tx_try(self, t):
        if self.core.wtx is None:
            return
        v = self.port.txf.first_valid(max(t, self.core.wtx[0]))
        if v is None:
            return
        if v > self.sim.now:
            self.sim.at(v, lambda: self._tx_try(v))
            return
        d, last = self.port.take_tx(self.sim.now)
        self.core.push_tx(self.sim.now, d, last)

    def _rx_move(self):
        now = self.sim.now
        if not self.core.out.tvalid(now):
            return
        self.port.rxf.sync(now)
        if self.port.rxf.full():
            return                                       # the CPU's next pop moves it
        d, last = self.core.take_rx(now)
        self.port.push_rx(now, d, last)

    def irq(self):
        return self.core.irq()


class Soc:
    """py_soc address map (py_soc_map_pkg.sv) and the board. ext: object with read(off) / write(off, d)
    for the external window 0x1_0000-0x1_FFFF (the video system)."""

    WIN = {0x0100: "sysctl", 0x1000: "intc", 0x2000: "wdt", 0x3000: "gpio0", 0x4000: "gpio1", 0x5000: "gpio2",
           0x6000: "uart0", 0x7000: "uart1", 0x8000: "i2c0", 0x9000: "i2c1", 0xA000: "spi0", 0xB000: "spi1",
           0xC000: "flash"}

    def __init__(self, sim, flash_image, board, ext=None, cfg=None):
        self.sim = sim
        self.src_reg, self.src_comb = [], []            # (the sources: below)
        self.comb_log, self.reg_log = [(0, 0)], [(0, 0)]   # (clock, condition vector) changes
        sim.on_event = self.update_irq
        self.board = board
        self.cfg = c = dict(CFG, **(cfg or {}))
        self.clk_en = 0
        self.ram = bytearray(RAM_BYTES)                 # data RAM (the RTL's is undefined until written: 0 here)
        dep = c["port_depth"]
        self.sysctl = SysCtl(self, c["nclk"], c["clk_en_rst"], c["clkgen"])
        self.intc = Intc(self)
        self.wdt = Wdt(self)
        nop = lambda v: None                             # noqa: E731
        self.gpio0, self.gpio1, self.gpio2 = (
            Gpio(self, getattr(board, f"gpio{n}_in", lambda o, t: 0), loopback=c["gpio_loopback"][n],
                 on_out=getattr(board, f"gpio{n}_out", nop)) for n in range(3))
        self.uart0 = UartPort(self, c["uart_baud"][0], dep, on_char=getattr(board, "uart0_char", None))
        self.uart1 = UartPort(self, c["uart_baud"][1], dep)
        if c["uart_cross"]:                              # each RX line is the other UART's TX line
            for a, b in ((self.uart0, self.uart1), (self.uart1, self.uart0)):
                b.core.rxd_source = a.core.txd_at
                a.core.on_txd_fell = b.core.rx_line_fell
        devs = getattr(board, "i2c_devices", None)
        self.i2c0 = I2cPort(self, c["i2c_hz"][0], devs(0) if devs else {0x36: board.camera}, dep)
        self.i2c1 = I2cPort(self, c["i2c_hz"][1], devs(1) if devs else {0x50: board.eeprom}, dep)
        self.spi0 = SpiPort(self, c["spi_hz"][0], dep)
        self.spi1 = SpiPort(self, c["spi_hz"][1], dep)
        self.flash = FlashPort(self, flash_image, dep)
        windows, ports = {}, {}
        for base, n in self.WIN.items():
            p = getattr(self, n)
            windows[base] = p.r
            if getattr(p, "port", None) is not None:
                ports[base] = p.port.r
        self.xbar = Xbar(windows, ports, c["ext_en"], c["ddr_en"])
        self.ext = ext
        self.ddr = None                                 # the DDR shared with the video system
        # interrupt sources (py_soc.sv irq_src): 0-1 UART, 2-3 I2C (data port OR done interrupt), 4-5 SPI,
        # 6-8 GPIO, 9 WDT, 10 flash, 11 flash data port, 12-15 external (video system), 16 SYSCTL timer.
        # src_reg: conditions the peripheral registers (gpio, py_stream_port: irq_o one clock later);
        # src_comb: irq_o from the state of the clock (i2c_master, watchdog, spi_flash_ctrl, py_sysctl)
        self.src_reg = [self.uart0.port.irq, self.uart1.port.irq, self.i2c0.port.irq, self.i2c1.port.irq,
                        self.spi0.port.irq, self.spi1.port.irq, self.gpio0.irq, self.gpio1.irq, self.gpio2.irq,
                        None, None, self.flash.port.irq, None, None, None, None, None]
        self.src_comb = [None, None, self.i2c0.core.irq, self.i2c1.core.irq, None, None, None, None, None,
                         self.wdt.irq, self.flash.irq, None, None, None, None, None, self.sysctl.timer_irq]
        self.core_reset_cb = lambda v: None
        self.boot_status = 1                            # SYSCTL BOOT_STATUS (boot() sets it)
        self.boot_ldr = None

    # the external windows are the crossbar's
    ext = property(lambda self: self.xbar.ext, lambda self, v: setattr(self.xbar, "ext", v))
    ddr = property(lambda self: self.xbar.ddr, lambda self, v: setattr(self.xbar, "ddr", v))

    def boot(self):
        """Run py_boot from clock 0 (the flash image, py_soc's BOOT_ADDR / FLASH_CLKDIV / CODE_AW) until done_o
        or err_o rises (sim.now is then that clock; the core starts in the next): True when loaded."""
        c = self.cfg
        b = self.boot_ldr = PyBoot(self, boot_addr=c["boot_addr"], clkdiv=c["flash_clkdiv"], code_aw=c["code_aw"])
        self.boot_status = 0
        ok = b.run(0)
        self.boot_status = int(ok) | int(b.err) << 1 | b.err_code << 4
        self.update_irq()
        return ok

    @property
    def boot_code(self):
        return bytes(self.boot_ldr.code)

    @property
    def boot_consts(self):
        return list(self.boot_ldr.consts)

    def core_reset(self, release):
        self.core_reset_cb(release)

    def set_ext_irq(self, i, fn):
        """External source 12 + i: fn() its level (synchronous to the CPU clock); its changes must fall on
        model events (the host schedules one where a level changes)."""
        self.src_comb[12 + i] = fn
        self.update_irq()

    @staticmethod
    def _vec(fns):
        v = 0
        for i, f in enumerate(fns):
            if f is not None and f():
                v |= 1 << i
        return v

    def _log(self, log, t, v):
        if log[-1][1] == v:
            return False
        if log[-1][0] == t:
            log[-1] = (t, v)                            # the clock's final value
            if len(log) > 1 and log[-2][1] == v:
                del log[-1]
        else:
            log.append((t, v))
            if len(log) > 4096:
                del log[:2048]
        return True

    def update_irq(self):
        """The interrupt sources may have changed in this clock (after every event and bus access): their
        intc inputs logged (a registered source's from the next clock) and the intc told."""
        now = self.sim.now
        if self._log(self.comb_log, now, self._vec(self.src_comb)):
            self.intc.input_changed(now)
        if self._log(self.reg_log, now, self._vec(self.src_reg)):
            self.intc.input_changed(now + 1)

    @staticmethod
    def _at(log, n):
        for t, v in reversed(log):
            if t <= n:
                return v
        return 0

    def irq_in(self, n):
        """py_soc's irq_src (the intc inputs) in clock n."""
        return self._at(self.comb_log, n) | self._at(self.reg_log, n - 1)

    # -- bus interface for the CPU
    def irq(self):
        return self.intc.irq()

    def tick(self, cycles):
        self.sim.advance(cycles)

    def budget(self):
        """Cycles until the next hardware event (the CPU runs that long without telling the bus)."""
        nt = self.sim.next_time()
        return 1 << 62 if nt is None else max(1, nt - self.sim.now)

    def timing(self, addr, write):
        """(effect, response) clocks of an access from its VALID clock (py_axil_xbar_model)."""
        return self.xbar.timing(addr, write)

    def read(self, addr):
        kind, tgt, off = self.xbar.decode(addr)
        if kind == "ram":
            return int.from_bytes(self.ram[off & ~3:(off & ~3) + 4], "little"), True
        if kind == "err" or tgt is None:
            return 0, False
        if kind == "ddr":
            return tgt.word(off & ~3), True
        d, resp = tgt.read(off)
        self.update_irq()                               # a read may pop a FIFO (RXDATA)
        return d, resp == 0

    def write(self, addr, d):
        kind, tgt, off = self.xbar.decode(addr)
        if kind == "ram":
            self.ram[off & ~3:(off & ~3) + 4] = (d & 0xFFFFFFFF).to_bytes(4, "little")
            return True
        if kind == "err" or tgt is None:
            return False
        if kind == "ddr":
            tgt.set_word(off & ~3, d)
            return True
        resp = tgt.write(off, d)
        for p in (self.gpio0, self.gpio1, self.gpio2):
            p.sample()
        self.update_irq()
        return resp == 0
