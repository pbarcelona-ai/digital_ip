"""video_processor firmware, part 1: py_soc CPU initialisation (library).

Imported by video_proc.py (the program; pyc.py inlines this file at its
"from video_init import *"). Everything here concerns the control CPU only:

  - the py_soc address map and peripheral register offsets;
  - text output on UART 0: putc, puts / say (strings from the flash string
    table, read through the flash controller), dec, hex32, result (one
    [PASS] / [FAIL] line, counted in passes / errors), heading;
  - cpu_isr(pending): the CPU's own interrupt sources (software interrupt,
    GPIO2 edge, watchdog pre-timeout), called by the program's handler;
  - cpu_init(start): report section 1 (boot-up sequence: reset cause, the
    boot image header read back from flash, boot status, SoC ID, start-up
    cycle count) and section 2 (peripheral self-test, one PASS / FAIL line
    each: system control, interrupt controller, GPIO loopback and edge
    interrupt, UART 1 / UART 0 loopback, SPI 0 / SPI 1 loopback, I2C 0
    camera control registers, I2C 1 EEPROM, SPI flash, watchdog);
  - section 3 (CPU register dump): every CPU peripheral register with a
    short description (skipped when the GPIO0[31] quick-simulation strap is
    high);
  - the last step of cpu_init: after a successful boot (every self-test
    passed) the core logic reset is released by writing SYSCTL CORE_RESET;
    the logic outside the CPU (the video datapath) is held in reset until
    then, and stays there when a self-test failed;
  - dump(), reg_line(), dump_port(): register dump helpers.

The interrupt handler must be installed (irq_handler) before cpu_init: the
self-test waits for interrupts.
"""
from machine import mem32          # ignored by pyc: mem32 is native

# ---------------- py_soc address map ----------------
SYSCTL = 0x0100
INTC = 0x1000
WDT = 0x2000
GPIO0 = 0x3000
GPIO1 = 0x4000
GPIO2 = 0x5000
UART0 = 0x6000
UART1 = 0x7000
I2C0 = 0x8000
I2C1 = 0x9000
SPI0 = 0xA000
SPI1 = 0xB000
FLASH = 0xC000
DPORT = 0x100                      # py_stream_port data port of each peripheral
STR_BASE = 0x8000                  # pyc string table in flash

# data port registers (py_stream_port)
TXDATA = 0x00
RXDATA = 0x04
PSTATUS = 0x08
RX_VALID = 1 << 31
LAST = 1 << 24
TX_READY = 2
TX_EMPTY = 8

# system control, interrupt controller, watchdog
RESET_CAUSE = 0x00
BOOT_STATUS = 0x04
CYCLES = 0x08
SOC_ID = 0x0C
CORE_RESET = 0x10                  # [0] 1 = release the core logic (video) reset
CLK_EN = 0x14                      # clock generator output enables
CLK_STATUS = 0x18                  # [0] clock generator outputs locked [1] clock generator present
INTC_ENABLE = 0x00
INTC_EDGE = 0x04
INTC_PENDING = 0x0C
INTC_SOFT = 0x10
INTC_MASKED = 0x18
IRQ_GPIO2 = 1 << 8
IRQ_WDT = 1 << 9
IRQ_SOFT = 1 << 15                 # software-set self-test source (13 / 14: frame counter)
W_CTRL = 0x00
W_TIMEOUT = 0x04
W_PRESCALE = 0x08
W_PRETIMEOUT = 0x0C
W_KICK = 0x14
W_STATUS = 0x18
WDT_KEY = 0x5AFEC0DE

# GPIO, UART, SPI, I2C, flash
G_OUT = 0x00
G_DIR = 0x04
G_IN = 0x08
G_SET = 0x0C
G_CLEAR = 0x10
G_INT_EN = 0x18
G_RISE_EN = 0x1C
G_FALL_EN = 0x20
G_INT_STATUS = 0x24
LED_RUN = 1 << 1                   # GPIO0[1]: "running" LED
QUICK_STRAP = 1 << 31              # GPIO0[31] input: quick simulation (register dumps skipped)
U_STATUS = 0x08
S_CTRL = 0x00
S_DIV = 0x04
S_WORD_LEN = 0x08
I_CTRL = 0x00
I_ADDR = 0x04
I_LEN = 0x08
I_STATUS = 0x10
I_EN = 1
I_START = 2
I_READ = 4
I_DONE = 2
I_NACK = 4
I_CLEAR = 0xE
F_CMD = 0x00
F_ADDR = 0x04
F_LEN = 0x08
F_CLKDIV = 0x0C
F_STATUS = 0x10
F_BUSY = 1
F_DONE = 2
F_READ_DATA = 1 << 16
F_ADDR_EN = 1 << 8
SENSOR_ADDR = 0x36                 # camera control interface on I2C 0
EEPROM_ADDR = 0x50
TMO = 20000

# ---------------- state (globals) ----------------
errors = 0
stage = 0
passes = 0
lead = 0
gpio_cnt = 0
wdt_cnt = 0
soft_cnt = 0


# ======================================================================= text output on UART 0

def putc(c):
    while not mem32[UART0 + DPORT + PSTATUS] & TX_READY:
        pass
    mem32[UART0 + DPORT + TXDATA] = c


def nl():
    putc(13)
    putc(10)


def flash_read(addr, n):
    """Start a READ (03h) of n bytes at addr; the bytes arrive on the flash data port."""
    while mem32[FLASH + F_STATUS] & F_BUSY:
        pass
    mem32[FLASH + F_ADDR] = addr
    mem32[FLASH + F_LEN] = n
    mem32[FLASH + F_STATUS] = F_DONE
    mem32[FLASH + F_CMD] = F_READ_DATA | F_ADDR_EN | 0x03


def flash_byte():
    d = mem32[FLASH + DPORT + RXDATA]
    while not d & RX_VALID:
        d = mem32[FLASH + DPORT + RXDATA]
    return d & 0xFF


def puts(h):
    """Print string handle h (pyc string table: 64-byte slots, length, continue flag, text)."""
    if h >= 256:                                      # handle decoding (pyc.py string table)
        slot = h
    else:
        slot = h & 255
    more = 1
    while more:
        a = STR_BASE + (slot << 6)
        flash_read(a, 2)
        n = flash_byte()
        more = flash_byte()
        if n:
            flash_read(a + 2, n)
            i = 0
            while i < n:
                putc(flash_byte())
                i += 1
        slot += 1


def say(h):
    puts(h)
    nl()


def hexs(v, top):
    """Hex digits of v from bit position top (28: 8 digits, 8: 3 digits) down to 0."""
    while top >= 0:
        d = (v >> top) & 15
        if d < 10:
            putc(48 + d)
        else:
            putc(55 + d)
        top -= 4


def hex32(v):
    puts("0x")
    hexs(v, 28)


def digit(v, p):
    global lead
    d = 0
    while v >= p:
        v -= p
        d += 1
    if d or lead or p == 1:
        putc(48 + d)
        lead = 1
    return v


def dec(v):
    global lead
    if v < 0:
        putc(45)
        v = 0 - v
    lead = 0
    v = digit(v, 1000000000)
    v = digit(v, 100000000)
    v = digit(v, 10000000)
    v = digit(v, 1000000)
    v = digit(v, 100000)
    v = digit(v, 10000)
    v = digit(v, 1000)
    v = digit(v, 100)
    v = digit(v, 10)
    digit(v, 1)


def signed32(v):
    if v >= 0x80000000:
        return v - 0x80000000 - 0x80000000
    return v


def result(ok, h):
    """One self-test line: [PASS] or [FAIL] and the description; counts the outcome."""
    global errors, passes
    if ok:
        puts("  [PASS] ")
        passes += 1
    else:
        puts("  [FAIL] ")
        errors += 1
    say(h)


def heading(h):
    nl()
    say(h)
    say("--------------------------------------------------------------")


def wait_set(addr, mask):
    t = 0
    while not mem32[addr] & mask and t < TMO:
        t += 1
    return t < TMO


def wait_clear(addr, mask):
    t = 0
    while mem32[addr] & mask and t < TMO:
        t += 1
    return t < TMO


def rx_word(port):
    """Next word from a data port's RX FIFO, or -1 after a timeout."""
    t = 0
    while t < TMO:
        d = mem32[port + DPORT + RXDATA]
        if d & RX_VALID:
            return d & 0xFFFFFF
        t += 1
    return -1


# ======================================================================= register dump

def reg_line(off, h, v):
    puts("  +0x")
    hexs(off, 8)
    puts("  ")
    puts(h)
    puts(" ")
    hex32(v)
    nl()


def dump(base, names, n):
    """n registers from base; names is a strings() block, one padded name + description each."""
    i = 0
    while i < n:
        reg_line(i << 2, names + i, mem32[base + (i << 2)])
        i += 1


def dump_port(base):
    """Data port: STATUS and IRQ_EN (TXDATA is write only, reading RXDATA would pop the FIFO)."""
    dump(base + DPORT + PSTATUS, strings(
        "PORT_STATUS  [0] rx valid [1] tx ready [3] tx empty   ",
        "PORT_IRQ_EN  [0] rx valid [1] tx ready [2] tx empty   "), 2)


# ======================================================================= interrupts

def cpu_isr(pending):
    """The CPU's own interrupt sources; pending = INTC MASKED."""
    global gpio_cnt, wdt_cnt, soft_cnt
    if pending & IRQ_SOFT:
        soft_cnt += 1
        mem32[INTC + INTC_PENDING] = IRQ_SOFT
    if pending & IRQ_GPIO2:
        s = mem32[GPIO2 + G_INT_STATUS]
        mem32[GPIO2 + G_INT_STATUS] = s                 # write 1 to clear
        gpio_cnt += 1
    if pending & IRQ_WDT:
        wdt_cnt += 1
        mem32[WDT + W_KICK] = WDT_KEY                   # serviced from the pre-timeout interrupt


# ======================================================================= 1. boot-up sequence

def boot_report(start_cycles):
    say("==============================================================")
    say(" video_processor  -  py_soc boot-up report (UART 0)")
    say("==============================================================")
    heading("1. Boot-up sequence")
    cause = mem32[SYSCTL + RESET_CAUSE]
    puts("  Reset released. Reset cause register ")
    hex32(cause)
    if cause & 2:
        say(": watchdog reset")
    else:
        say(": external reset (rst_n)")
    mem32[SYSCTL + RESET_CAUSE] = 3                   # write 1 to clear
    flash_read(0, 12)                                 # the boot image header py_boot checked
    # read the whole header before printing: puts() reads its text from the flash too
    magic = flash_byte() | (flash_byte() << 8) | (flash_byte() << 16) | (flash_byte() << 24)
    code = flash_byte() | (flash_byte() << 8)
    consts = flash_byte() | (flash_byte() << 8)
    csum = flash_byte() | (flash_byte() << 8) | (flash_byte() << 16) | (flash_byte() << 24)
    puts("  py_boot read the boot image from SPI flash, magic \"")
    i = 0
    while i < 4:
        putc((magic >> (i << 3)) & 0xFF)
        i += 1
    say("\"")
    puts("    program code      ")
    dec(code)
    say(" bytes copied to code memory")
    puts("    constants         ")
    dec(consts)
    say(" x 34-bit words copied to the constant pool")
    puts("    payload checksum  ")
    hex32(csum)
    nl()
    st = mem32[SYSCTL + BOOT_STATUS]
    puts("  Boot status ")
    hex32(st)
    if st & 2:
        puts(": BOOT ERROR, code ")
        dec((st >> 4) & 7)
        nl()
    else:
        say(": image accepted (magic, sizes, checksum OK)")
    puts("  py_core started at pc 0, ")
    dec(start_cycles)
    say(" CPU clock cycles after reset")
    puts("  SoC ID ")
    hex32(mem32[SYSCTL + SOC_ID])
    say(" (\"PY\", version 1.0); text from the flash string table")


# ======================================================================= 2. CPU peripheral self-test

def test_sysctl():
    c0 = mem32[SYSCTL + CYCLES]
    c1 = mem32[SYSCTL + CYCLES]
    result(mem32[SYSCTL + SOC_ID] == 0x50590100, "SYSCTL: SoC ID reads 0x50590100")
    result(c1 > c0, "SYSCTL: free-running cycle counter advances")
    result(mem32[SYSCTL + BOOT_STATUS] & 1, "SYSCTL: boot-done flag set, no boot error")
    result(mem32[SYSCTL + CLK_STATUS] == 3, "SYSCTL: clock generator present, all clocks locked")


def test_gpio():
    mem32[GPIO1 + G_DIR] = 0xFFFFFFFF                  # bank 1 drives its own inputs (board loopback)
    mem32[GPIO1 + G_OUT] = 0xA5A55A5A
    t = 0
    while t < 4:
        t += 1
    a = mem32[GPIO1 + G_IN]
    mem32[GPIO1 + G_OUT] = 0x5A5AA5A5
    t = 0
    while t < 4:
        t += 1
    b = mem32[GPIO1 + G_IN]
    result(a == 0xA5A55A5A and b == 0x5A5AA5A5, "GPIO1: 32-bit loopback, patterns A5A55A5A / 5A5AA5A5")
    mem32[GPIO2 + G_DIR] = 1
    mem32[GPIO2 + G_RISE_EN] = 1
    mem32[GPIO2 + G_INT_EN] = 1
    mem32[GPIO2 + G_SET] = 1                           # rising edge on GPIO2[0]
    t = 0
    while gpio_cnt == 0 and t < TMO:
        t += 1
    result(gpio_cnt > 0, "GPIO2: rising edge on pin 0 raises interrupt 8")


def test_uart1():
    i = 0
    while i < 4:
        mem32[UART1 + DPORT + TXDATA] = 0x30 + i
        i += 1
    ok = 1
    i = 0
    while i < 4:
        if rx_word(UART1) != 0x30 + i:
            ok = 0
        i += 1
    result(ok, "UART1: 4 bytes sent and received back (txd looped to rxd)")


def test_uart0():
    puts("  ... UART0 echo: sending 'U' -> ")
    wait_set(UART0 + DPORT + PSTATUS, TX_EMPTY)      # let the report text drain
    wait_clear(UART0 + U_STATUS, 1)
    while mem32[UART0 + DPORT + RXDATA] & RX_VALID:   # the report itself is echoed: drop it
        pass
    putc(0x55)
    nl()
    result(rx_word(UART0) == 0x55, "UART0: character echoed back through the loopback")


def test_spi():
    mem32[SPI0 + S_DIV] = 2
    mem32[SPI0 + S_WORD_LEN] = 16
    mem32[SPI0 + S_CTRL] = 1
    mem32[SPI0 + DPORT + TXDATA] = LAST | 0xBEEF
    result(rx_word(SPI0) & 0xFFFF == 0xBEEF, "SPI0: 16-bit word 0xBEEF looped MOSI -> MISO")
    mem32[SPI1 + S_DIV] = 2
    mem32[SPI1 + S_WORD_LEN] = 16
    mem32[SPI1 + S_CTRL] = (1 << 8) | 1                # chip select 1
    mem32[SPI1 + DPORT + TXDATA] = 0x1234
    mem32[SPI1 + DPORT + TXDATA] = LAST | 0xABCD
    a = rx_word(SPI1) & 0xFFFF
    b = rx_word(SPI1) & 0xFFFF
    result(a == 0x1234 and b == 0xABCD, "SPI1: 2-word burst on chip select 1 looped back")


def i2c_go(bus, addr, n, rd):
    mem32[bus + I_ADDR] = addr
    mem32[bus + I_LEN] = n
    mem32[bus + I_STATUS] = I_CLEAR
    mem32[bus + I_CTRL] = I_EN | I_START | rd
    if not wait_set(bus + I_STATUS, I_DONE):
        return 0
    return not mem32[bus + I_STATUS] & I_NACK


def test_i2c():
    mem32[I2C0 + DPORT + TXDATA] = 0x10                # sensor register pointer
    mem32[I2C0 + DPORT + TXDATA] = 0xC3
    mem32[I2C0 + DPORT + TXDATA] = 0x3C
    ok = i2c_go(I2C0, SENSOR_ADDR, 3, 0)
    mem32[I2C0 + DPORT + TXDATA] = 0x10
    ok = ok and i2c_go(I2C0, SENSOR_ADDR, 1, 0)
    ok = ok and i2c_go(I2C0, SENSOR_ADDR, 2, I_READ)
    a = rx_word(I2C0) & 0xFF
    b = rx_word(I2C0) & 0xFF
    result(ok and a == 0xC3 and b == 0x3C, "I2C0: camera control (0x36) regs 0x10-0x11 written, read back")
    mem32[I2C1 + DPORT + TXDATA] = 0x00                # EEPROM address
    i = 0
    while i < 4:
        mem32[I2C1 + DPORT + TXDATA] = 0x11 + (i << 4) + i
        i += 1
    ok = i2c_go(I2C1, EEPROM_ADDR, 5, 0)
    mem32[I2C1 + DPORT + TXDATA] = 0x00
    ok = ok and i2c_go(I2C1, EEPROM_ADDR, 1, 0)
    ok = ok and i2c_go(I2C1, EEPROM_ADDR, 4, I_READ)
    i = 0
    while i < 4:
        if rx_word(I2C1) & 0xFF != 0x11 + (i << 4) + i:
            ok = 0
        i += 1
    result(ok, "I2C1: EEPROM (0x50) 4 bytes written, read back")


def test_flash():
    while mem32[FLASH + F_STATUS] & F_BUSY:
        pass
    mem32[FLASH + F_LEN] = 3
    mem32[FLASH + F_STATUS] = F_DONE
    mem32[FLASH + F_CMD] = F_READ_DATA | 0x9F
    a = flash_byte()
    b = flash_byte()
    c = flash_byte()
    result(a == 0xEF and b == 0x40 and c == 0x17, "FLASH: JEDEC ID EF 40 17 (read ID, 9Fh)")
    flash_read(0, 4)
    m = flash_byte() | (flash_byte() << 8) | (flash_byte() << 16) | (flash_byte() << 24)
    result(m == 0x31435950, "FLASH: boot image magic \"PYC1\" read back (03h)")


def test_intc():
    mem32[INTC + INTC_SOFT] = IRQ_SOFT                 # software-set source 15
    t = 0
    while soft_cnt == 0 and t < TMO:
        t += 1
    result(soft_cnt > 0, "INTC: software interrupt 15 taken by the handler")


def test_wdt():
    mem32[WDT + W_PRESCALE] = 9                        # one tick per 10 clocks
    mem32[WDT + W_PRETIMEOUT] = 50
    mem32[WDT + W_TIMEOUT] = 100
    mem32[WDT + W_CTRL] = 1
    t = 0
    while wdt_cnt < 3 and t < TMO:
        t += 1
    mem32[WDT + W_CTRL] = 0
    mem32[WDT + W_STATUS] = 15
    result(wdt_cnt >= 3, "WDT: 3 pre-timeout interrupts, kicked each time, then disabled")


# ======================================================================= CPU initialisation

def cpu_init(start):
    """Report sections 1-3 (boot-up, self-test, CPU register dump); start = CYCLES when the program
    started. Leaves the CPU's interrupt sources enabled and interrupts on (the handler must already
    be installed). Nothing outside the CPU is touched; at the end, if every self-test passed, the
    core logic reset is released (SYSCTL CORE_RESET). Returns 1 when the core logic is running."""
    global stage
    mem32[FLASH + F_CLKDIV] = 3                        # fastest flash clock for the text
    stage = 1
    mem32[GPIO0 + G_OUT] = 0
    mem32[GPIO0 + G_DIR] = LED_RUN
    mem32[INTC + INTC_EDGE] = IRQ_SOFT
    mem32[INTC + INTC_ENABLE] = IRQ_GPIO2 | IRQ_WDT | IRQ_SOFT
    irq_enable()
    boot_report(start)
    stage = 2
    heading("2. CPU peripheral self-test")
    test_sysctl()
    test_intc()
    test_gpio()
    test_uart1()
    test_uart0()
    test_spi()
    test_i2c()
    test_flash()
    test_wdt()
    stage = 3
    heading("3. CPU register dump (offset  name  description  value)")
    if mem32[GPIO0 + G_IN] & QUICK_STRAP:
        say(" (skipped: GPIO0[31] quick-simulation strap)")
    else:
        dump_cpu()
    nl()
    if errors:
        say(" CPU initialisation FAILED: core logic (video) kept in reset")
        return 0
    result(mem32[SYSCTL + CORE_RESET] == 0, "SYSCTL: core logic held in reset during the CPU boot and self-test")
    mem32[SYSCTL + CORE_RESET] = 1                     # release the core logic (video datapath)
    result(mem32[SYSCTL + CORE_RESET] == 1, "SYSCTL: core logic reset released (CORE_RESET = 1)")
    say(" CPU initialisation complete")
    return 1


# ======================================================================= register dump (CPU part)

def dump_cpu():
    say(" SYSCTL @ 0x0100")
    dump(SYSCTL, strings(
        "RESET_CAUSE  [0] external [1] watchdog (sticky)       ",
        "BOOT_STATUS  [0] done [1] error [6:4] error code      ",
        "CYCLES       free-running clock cycle counter         ",
        "ID           SoC ID: \"PY\" version 1.0               ",
        "CORE_RESET   [0] 1 = core logic out of reset          ",
        "CLK_EN       clock output enables                     ",
        "CLK_STATUS   [0] clocks locked [1] generator present  "), 7)
    say(" INTC @ 0x1000")
    dump(INTC, strings(
        "ENABLE       interrupt enable mask                    ",
        "EDGE_TYPE    1 = edge, 0 = level, per source          ",
        "ACTIVE_LOW   1 = active-low source                    ",
        "PENDING      pending sources (W1C for edge sources)   ",
        "SOFT_SET     software set (write only)                ",
        "VECTOR       [4:0] highest pending [31] valid         ",
        "MASKED       pending AND enabled                      "), 7)
    say(" WDT @ 0x2000")
    dump(WDT, strings(
        "CTRL         [0] enable [1] window [2] lock           ",
        "TIMEOUT      reset after this many ticks              ",
        "PRESCALE     clock cycles per tick - 1                ",
        "PRETIMEOUT   interrupt after this many ticks          ",
        "WINDOW_OPEN  earliest legal kick (window mode)        ",
        "KICK         write 0x5AFEC0DE to restart              ",
        "STATUS       [0] pre [1] expired [2] early [3] key    ",
        "COUNT        current tick count                       "), 8)
    b = 0
    while b < 3:
        puts(" GPIO")
        dec(b)
        puts(" @ ")
        hex32(GPIO0 + (b << 12))
        nl()
        dump(GPIO0 + (b << 12), strings(
            "OUT          output register                          ",
            "DIR          1 = output                               ",
            "IN           pin levels (synchronised)                ",
            "SET          write 1s: set OUT bits                   ",
            "CLEAR        write 1s: clear OUT bits                 ",
            "TOGGLE       write 1s: toggle OUT bits                ",
            "INT_EN       interrupt enable per pin                 ",
            "RISE_EN      rising-edge interrupt enable             ",
            "FALL_EN      falling-edge interrupt enable            ",
            "INT_STATUS   edge status (W1C)                        "), 10)
        b += 1
    b = 0
    while b < 2:
        puts(" UART")
        dec(b)
        puts(" @ ")
        hex32(UART0 + (b << 12))
        nl()
        dump(UART0 + (b << 12), strings(
            "CTRL         [0] tx [1] rx [2] parity [4] 2 stop      ",
            "FCW          baud word = baud * 16 * 2^32 / f_clk     ",
            "STATUS       [0] tx busy [1] rx busy [10] overrun     ",
            "ERRORS       frames received with errors              "), 4)
        dump_port(UART0 + (b << 12))
        b += 1
    b = 0
    while b < 2:
        puts(" I2C")
        dec(b)
        puts(" @ ")
        hex32(I2C0 + (b << 12))
        nl()
        dump(I2C0 + (b << 12), strings(
            "CTRL         [0] en [1] start [2] read [3] no stop    ",
            "ADDR         7-bit target address                     ",
            "LEN          bytes to transfer                        ",
            "DIV          SCL = f_clk / (4 * (DIV + 1))            ",
            "STATUS       [0] busy [1] done [2] nack [3] arb lost  "), 5)
        dump_port(I2C0 + (b << 12))
        b += 1
    b = 0
    while b < 2:
        puts(" SPI")
        dec(b)
        puts(" @ ")
        hex32(SPI0 + (b << 12))
        nl()
        dump(SPI0 + (b << 12), strings(
            "CTRL         [0] en [1] cpol [2] cpha [15:8] cs       ",
            "DIV          SCLK half period = DIV + 1 clocks        ",
            "WORD_LEN     bits per word                            ",
            "STATUS       [0] busy [1] overrun [31:16] rx level    "), 4)
        dump_port(SPI0 + (b << 12))
        b += 1
    say(" FLASH @ 0xC000")
    dump(FLASH, strings(
        "CMD          last command: opcode, addr, dummy, dir   ",
        "ADDR         24-bit flash address                     ",
        "LEN          data bytes                               ",
        "CLKDIV       SCLK half period in clocks               ",
        "STATUS       [0] busy [1] done [2] command error      ",
        "IRQ_EN       [0] done interrupt                       ",
        "VERSION      controller version                       "), 7)
    dump_port(FLASH)
