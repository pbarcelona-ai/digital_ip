"""video_processor firmware, part 1: py_soc CPU initialisation (library).

Imported by video_proc.py (the program; pyc.py inlines this file at its
"from video_init import *"). Everything here concerns the control CPU only:

  - the py_soc address map and peripheral register offsets;
  - text output on UART 0: putc, puts / say (strings from the flash string
    table, read through the flash controller), dec, hex32, result (one
    [PASS] / [FAIL] line, counted in passes / errors), heading; with the
    GPIO0[28] direct-transcript strap the text goes instead to the GPIO1
    transcript port (one write per character, no UART wait: the testbench
    writes it straight to the transcript file) and only the tracking
    sections are written (con: 0 muted, 1 UART 0, 2 transcript port);
  - cpu_isr(pending): the CPU's own interrupt sources (software interrupt,
    GPIO2 edge, watchdog pre-timeout, timer, the wake sources), called by
    the program's handler;
  - waiting without polling: wait_bit / port_wait / rx_word / pause sleep
    on the peripheral's interrupt (py_core WAIT_IRQ, interrupts disabled
    around the test so none is missed), every sleep bounded by the SYSCTL
    timer compare interrupt (TMO);
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
from py_soc_map_pkg import *       # py_soc register windows (src/py_soc_map_pkg.sv, pyc.py -I)
SYSCTL = SYSCTL_BASE
INTC = INTC_BASE
WDT = WDT_BASE
GPIO0 = GPIO0_BASE
GPIO1 = GPIO1_BASE
GPIO2 = GPIO2_BASE
UART0 = UART0_BASE
UART1 = UART1_BASE
I2C0 = I2C0_BASE
I2C1 = I2C1_BASE
SPI0 = SPI0_BASE
SPI1 = SPI1_BASE
FLASH = FLASH_BASE
# DPORT (py_soc_map_pkg): the py_stream_port data port of each peripheral
STR_BASE = 0x8000                  # pyc string table in flash

# data port registers (py_stream_port: ID block 0x00-0x0F, registers from 0x10)
TXDATA = 0x10
RXDATA = 0x14
PSTATUS = 0x18
RX_VALID = 1 << 31
LAST = 1 << 24
TX_READY = 2
TX_EMPTY = 8
PIRQ_EN = 0x1C                     # data port IRQ_EN: [0] RX FIFO not empty [1] TX FIFO not full [2] TX FIFO empty
P_RX = 1
P_TXR = 2
P_TXE = 4

# system control, interrupt controller, watchdog
RESET_CAUSE = 0x10
BOOT_STATUS = 0x14
CYCLES = 0x18
SOC_ID = 0x1C
CORE_RESET = 0x20                  # [0] 1 = release the core logic (video) reset
CLK_EN = 0x24                      # clock generator output enables
CLK_STATUS = 0x28                  # [0] clock generator outputs locked [1] clock generator present
TIMER_CMP = 0x2C                   # timer compare: TIMER_STATUS.REACHED when CYCLES reaches it (interrupt 16)
TIMER_CTRL = 0x30                  # [0] timer interrupt enable
INTC_ENABLE = 0x10
INTC_EDGE = 0x14
INTC_PENDING = 0x1C
INTC_SOFT = 0x20
INTC_MASKED = 0x28
IRQ_UART0 = 1 << 0                 # intc sources (py_soc irq_src): data port of UART 0 / 1,
IRQ_UART1 = 1 << 1
IRQ_I2C0 = 1 << 2                  # I2C 0 / 1 (done interrupt or data port),
IRQ_I2C1 = 1 << 3
IRQ_SPI0 = 1 << 4                  # SPI 0 / 1 data port,
IRQ_SPI1 = 1 << 5
IRQ_GPIO2 = 1 << 8
IRQ_WDT = 1 << 9
IRQ_FLASH = 1 << 10                # flash controller done,
IRQ_FPORT = 1 << 11                # flash data port,
IRQ_SOFT = 1 << 15                 # software-set self-test source (13 / 14: frame counter)
IRQ_TIMER = 1 << 16                # SYSCTL timer compare
IRQ_WAKE = 0x0C3F                  # the sources a wait sleeps on (wait_bit): masked by the handler when they come
W_CTRL = 0x10
W_TIMEOUT = 0x14
W_PRESCALE = 0x18
W_PRETIMEOUT = 0x1C
W_KICK = 0x24
W_STATUS = 0x28
WDT_KEY = 0x5AFEC0DE

# GPIO, UART, SPI, I2C, flash (gpio map: ID block 0x00-0x0F, registers from 0x10)
G_OUT = 0x10
G_DIR = 0x14
G_IN = 0x18
G_SET = 0x1C
G_CLEAR = 0x20
G_INT_EN = 0x28
G_RISE_EN = 0x2C
G_FALL_EN = 0x30
G_INT_STATUS = 0x34
LED_RUN = 1 << 1                   # GPIO0[1]: "running" LED
QUICK_STRAP = 1 << 31              # GPIO0[31] input: quick simulation (register dumps of sections 3 and 5 skipped)
DIRECT_STRAP = 1 << 28             # GPIO0[28] input: direct transcript (tracking text on the GPIO1 port, the rest muted)
TPORT = 0xDB000000                 # GPIO1 transcript port word: [31:24] 0xDB marker, [8] toggles per character, [7:0] it
U_STATUS = 0x18                    # uart map: ID block 0x00-0x0F, CTRL 0x10, FCW 0x14, STATUS 0x18
S_CTRL = 0x10
S_DIV = 0x14
S_WORD_LEN = 0x18
I_CTRL = 0x10
I_ADDR = 0x14
I_LEN = 0x18
I_STATUS = 0x20
I_EN = 1
I_START = 2
I_READ = 4
I_DONE = 2
I_NACK = 4
I_CLEAR = 0xE
I_IRQ_EN = 0x24                    # [0] done interrupt
F_CMD = 0x10
F_ADDR = 0x14
F_LEN = 0x18
F_CLKDIV = 0x1C
F_STATUS = 0x20
F_BUSY = 1
F_DONE = 2
F_READ_DATA = 1 << 16
F_ADDR_EN = 1 << 8
F_IRQ_EN = 0x24                    # [0] done interrupt
SENSOR_ADDR = 0x36                 # camera control interface on I2C 0
EEPROM_ADDR = 0x50
TMO = 2000000                      # 10 ms (CPU clock cycles at 200 MHz): a wait for the hardware gives up
CHAR_CYC = 17400                   # one UART character at 115200 baud (10 bits): 87 us

# ---------------- state (globals) ----------------
errors = 0
stage = 0
passes = 0
lead = 0
gpio_cnt = 0
wdt_cnt = 0
soft_cnt = 0
log_wr = 0                         # 1: wreg() reports every register write on UART 0 (set-up phases)
con = 1                            # text output: 0 muted, 1 UART 0, 2 GPIO1 transcript port (direct strap)


# ======================================================================= text output on UART 0

def direct():
    """1 with the GPIO0[28] direct-transcript strap (only the tracking is written)."""
    return mem32[GPIO0 + G_IN] & DIRECT_STRAP


def putc(c):
    if con == 2:                                       # transcript port: one GPIO1 write (toggle [8]), no wait
        mem32[GPIO1 + G_OUT] = TPORT | ((mem32[GPIO1 + G_OUT] & 0x100) ^ 0x100) | c
        return
    if con == 0:
        return
    if not mem32[UART0 + DPORT + PSTATUS] & TX_READY:  # FIFO full: sleep until it has room
        mem32[UART0 + DPORT + PIRQ_EN] = P_TXR
        wait_bit(UART0 + DPORT + PSTATUS, TX_READY, 1, IRQ_UART0)
        mem32[UART0 + DPORT + PIRQ_EN] = 0
    mem32[UART0 + DPORT + TXDATA] = c


def nl():
    putc(13)
    putc(10)


def putw(w):
    """Up to 4 characters packed in w, the first in [7:0], ended by a 0 byte: text printed without
    reading the flash string table (the per-frame tracking lines; a flash read is several us)."""
    while w:
        putc(w & 255)
        w = w >> 8


def flash_read(addr, n):
    """Start a READ (03h) of n bytes at addr; the bytes arrive on the flash data port. 0 when the
    controller stays busy (timeout), else 1."""
    if not wait_bit(FLASH + F_STATUS, F_BUSY, 0, IRQ_FLASH):
        return 0
    mem32[FLASH + F_ADDR] = addr
    mem32[FLASH + F_LEN] = n
    mem32[FLASH + F_STATUS] = F_DONE
    mem32[FLASH + F_CMD] = F_READ_DATA | F_ADDR_EN | 0x03
    return 1


def flash_byte():
    """Next byte of a flash read (0 after a timeout: the read never delivers it)."""
    d = mem32[FLASH + DPORT + RXDATA]
    if not d & RX_VALID:                               # none yet: sleep on the data port's interrupt
        mem32[FLASH + DPORT + PIRQ_EN] = P_RX
        wait_bit(FLASH + DPORT + PSTATUS, 1, 1, IRQ_FPORT)
        mem32[FLASH + DPORT + PIRQ_EN] = 0
        d = mem32[FLASH + DPORT + RXDATA]
    return d & 0xFF


def str_addr(h):
    """Flash address of string handle h's first slot (pyc string table: 64-byte slots, length,
    continue flag, text)."""
    if h >= 256:                                      # handle decoding (pyc.py string table)
        return STR_BASE + (h << 6)
    return STR_BASE + ((h & 255) << 6)


def str_len(h):
    """Length of string handle h's first slot (0: empty string)."""
    flash_read(str_addr(h), 1)
    return flash_byte()


def puts(h):
    """Print string handle h."""
    if con == 0:                                       # muted: not even read from flash
        return
    slot = (str_addr(h) - STR_BASE) >> 6
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
    if v < 1000:                                       # fast path (coordinates, counts): shifts only
        h = ((v << 5) + (v << 3) + v) >> 12            # v // 100 = 41 v >> 12 for v < 1000
        v = v - ((h << 6) + (h << 5) + (h << 2))
        t = ((v << 7) + (v << 6) + (v << 3) + (v << 2) + v) >> 11   # v // 10 = 205 v >> 11 for v < 100
        if h:
            putc(48 + h)
        if h or t:
            putc(48 + t)
        putc(48 + v - ((t << 3) + (t << 1)))
        return
    lead = 0
    if v >= 10000:                                     # small numbers (most of the text) skip the high digits
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


# ---- waiting for the hardware: interrupts, no polling loops. The core sleeps (wait_irq, py_core
# WAIT_IRQ) with interrupts disabled until an enabled source is pending, then lets the handler run;
# every sleep is bounded by the SYSCTL timer compare interrupt (16), so a wait can time out.

def deadline(n):
    """CYCLES + n (mod 2**32): the end of a wait of n cycles (n < 2**31)."""
    c = mem32[SYSCTL + CYCLES]
    if c > 0xFFFFFFFF - n:
        c = c - 0x80000000 - 0x80000000                # (no 2**32 literal: it is not a small int)
    return (c + n) & 0xFFFFFFFF


def passed(t):
    """True once CYCLES has reached t (wrap-safe)."""
    return (mem32[SYSCTL + CYCLES] - t) & 0xFFFFFFFF < 0x80000000


def sleep_until(t):
    """Interrupts disabled: sleep until an interrupt comes, at the latest when CYCLES reaches t (the
    timer interrupt; the handler turns it off), let the handler run, then disable them again."""
    mem32[SYSCTL + TIMER_CMP] = t
    mem32[SYSCTL + TIMER_CTRL] = 1
    wait_irq()
    irq_enable()
    irq_disable()


def pause(n):
    """Sleep n cycles (other interrupts are served meanwhile)."""
    t = deadline(n)
    irq_disable()
    while not passed(t):
        sleep_until(t)
    irq_enable()


def wait_bit(addr, mask, want, src):
    """Sleep until mem32[addr] & mask is non-zero (want 1) or zero (want 0); src: the intc source
    whose interrupt says so, enabled while waiting (the handler masks it again when it comes). 1, or
    0 when TMO cycles pass first. A leaf (deadline, passed and sleep_until written out): it is called
    from deep in the text output and py_core has 16 call frames, one kept for the handler."""
    t = mem32[SYSCTL + CYCLES]
    if t > 0xFFFFFFFF - TMO:
        t = t - 0x80000000 - 0x80000000
    t = (t + TMO) & 0xFFFFFFFF
    irq_disable()
    ok = 1
    while True:
        v = mem32[addr] & mask
        if want:
            if v:
                break
        elif v == 0:
            break
        if (mem32[SYSCTL + CYCLES] - t) & 0xFFFFFFFF < 0x80000000:
            ok = 0
            break
        mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] | src
        mem32[SYSCTL + TIMER_CMP] = t
        mem32[SYSCTL + TIMER_CTRL] = 1
        wait_irq()
        irq_enable()
        irq_disable()
    mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] & ~src
    irq_enable()
    return ok


def port_src(port):
    """intc source of a peripheral's data port (I2C: shared with its done interrupt)."""
    if port == UART0:
        return IRQ_UART0
    if port == UART1:
        return IRQ_UART1
    if port == I2C0:
        return IRQ_I2C0
    if port == I2C1:
        return IRQ_I2C1
    if port == SPI0:
        return IRQ_SPI0
    if port == SPI1:
        return IRQ_SPI1
    return IRQ_FPORT


def port_wait(port, en, bit):
    """Sleep until the data port's PSTATUS bit is set, on its interrupt (IRQ_EN en); 1, or 0 on timeout."""
    mem32[port + DPORT + PIRQ_EN] = en
    ok = wait_bit(port + DPORT + PSTATUS, bit, 1, port_src(port))
    mem32[port + DPORT + PIRQ_EN] = 0
    return ok


def rx_word(port):
    """Next word from a data port's RX FIFO (sleeping until one arrives), or -1 after a timeout."""
    d = mem32[port + DPORT + RXDATA]
    if d & RX_VALID:
        return d & 0xFFFFFF
    if port_wait(port, P_RX, 1):
        d = mem32[port + DPORT + RXDATA]
        if d & RX_VALID:
            return d & 0xFFFFFF
    return -1


# ======================================================================= register dump

def reg_line(addr, h, v):
    puts("  0x")
    hexs(addr, 16)
    puts("  ")
    puts(h)
    puts(" ")
    hex32(v)
    nl()


def wreg(addr, v, h):
    """Write v to the register at addr. While log_wr is set (set-up phases) the write is reported on
    UART 0: h is a strings() block of three entries, "<module> <register>" and two lines saying what
    the change does (the second may be ""), printed as
        <module> <register>
          old value 0x........
          new value 0x........   (read back after the write)
          <what the change does>"""
    if not log_wr or direct():
        mem32[addr] = v
        return
    old = mem32[addr]
    mem32[addr] = v
    new = mem32[addr]
    say(h)
    puts("  old value ")
    hex32(old)
    nl()
    puts("  new value ")
    hex32(new)
    nl()
    puts("  ")
    say(h + 1)
    if str_len(h + 2):
        puts("  ")
        say(h + 2)


def dump(base, names, n):
    """n registers from base; names is a strings() block, one padded name + description each."""
    i = 0
    while i < n:
        reg_line(base + (i << 2), names + i, mem32[base + (i << 2)])
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
    if pending & IRQ_TIMER:                             # a sleep's time is up: the timer off until the
        mem32[SYSCTL + TIMER_CTRL] = 0                  # next sleep_until
    if pending & IRQ_WAKE:                              # what a wait sleeps on: masked, the waiting code
        mem32[INTC + INTC_ENABLE] = mem32[INTC + INTC_ENABLE] & ~(pending & IRQ_WAKE)   # tests it


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
    t = deadline(TMO)
    irq_disable()
    while gpio_cnt == 0 and not passed(t):             # the handler counts it
        sleep_until(t)
    irq_enable()
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


def uart_drain():
    """Sleep until UART 0 has sent everything and the echo of it is back: the data port's TX FIFO empty
    (interrupt), then the UART's own FIFO (2 words) and shift register (4 character times), then its TX and
    RX engines idle (STATUS [1:0]; the UART has no interrupt for that)."""
    port_wait(UART0, P_TXE, TX_EMPTY)
    pause(4 * CHAR_CYC)
    while mem32[UART0 + U_STATUS] & 3:
        pause(CHAR_CYC)


def test_uart0():
    puts("  ... UART0 echo: sending 'U' -> ")
    uart_drain()                                       # let the report text go out
    while mem32[UART0 + DPORT + RXDATA] & RX_VALID:   # the report itself is echoed: drop it (each read
        pass                                           # takes one character out of the RX FIFO)
    mem32[UART0 + DPORT + TXDATA] = 0x55               # on the UART itself (the text may go elsewhere)
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
    if not wait_bit(bus + I_STATUS, I_DONE, 1, port_src(bus)):   # the done interrupt
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
    wait_bit(FLASH + F_STATUS, F_BUSY, 0, IRQ_FLASH)
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
    t = deadline(TMO)
    irq_disable()
    while soft_cnt == 0 and not passed(t):
        sleep_until(t)
    irq_enable()
    result(soft_cnt > 0, "INTC: software interrupt 15 taken by the handler")


def test_wdt():
    mem32[WDT + W_PRESCALE] = 9                        # one tick per 10 clocks
    mem32[WDT + W_PRETIMEOUT] = 50
    mem32[WDT + W_TIMEOUT] = 100
    mem32[WDT + W_CTRL] = 1
    t = deadline(TMO)
    irq_disable()
    while wdt_cnt < 3 and not passed(t):               # pre-timeout interrupts, kicked by the handler
        sleep_until(t)
    irq_enable()
    mem32[WDT + W_CTRL] = 0
    mem32[WDT + W_STATUS] = 15
    result(wdt_cnt >= 3, "WDT: 3 pre-timeout interrupts, kicked each time, then disabled")


# ======================================================================= CPU initialisation

def cpu_init(start):
    """Report sections 1-3 (boot-up, self-test, CPU register dump); start = CYCLES when the program
    started. Leaves the CPU's interrupt sources enabled and interrupts on (the handler must already
    be installed). Nothing outside the CPU is touched; at the end, if every self-test passed, the
    core logic reset is released (SYSCTL CORE_RESET). Returns 1 when the core logic is running."""
    global stage, con
    mem32[FLASH + F_CLKDIV] = 3                        # fastest flash clock for the text
    if direct():                                       # direct transcript: sections 1-7 not written
        con = 0
    stage = 1
    mem32[GPIO0 + G_OUT] = 0
    mem32[GPIO0 + G_DIR] = LED_RUN
    mem32[INTC + INTC_EDGE] = IRQ_SOFT
    mem32[INTC + INTC_ENABLE] = IRQ_GPIO2 | IRQ_WDT | IRQ_SOFT | IRQ_TIMER
    mem32[FLASH + F_IRQ_EN] = 1                        # done interrupts (enabled at the intc only while
    mem32[I2C0 + I_IRQ_EN] = 1                         # a wait sleeps on them)
    mem32[I2C1 + I_IRQ_EN] = 1
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
    heading("3. CPU register dump (address  name  description  value)")
    if mem32[GPIO0 + G_IN] & QUICK_STRAP or direct():
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
        "ID           \"SCTL\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(SYSCTL + 0x10, strings(
        "RESET_CAUSE  [0] external [1] watchdog (sticky)       ",
        "BOOT_STATUS  [0] done [1] error [6:4] error code      ",
        "CYCLES       free-running clock cycle counter         ",
        "SOC_ID       SoC ID: \"PY\" version 1.0                 ",
        "CORE_RESET   [0] 1 = core logic out of reset          ",
        "CLK_EN       clock output enables                     ",
        "CLK_STATUS   [0] clocks locked [1] generator present  "), 7)
    say(" INTC @ 0x1000")
    dump(INTC, strings(
        "ID           \"INTC\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(INTC + 0x10, strings(
        "ENABLE       interrupt enable mask                    ",
        "EDGE_TYPE    1 = edge, 0 = level, per source          ",
        "ACTIVE_LOW   1 = active-low source                    ",
        "PENDING      pending sources (W1C for edge sources)   ",
        "SOFT_SET     software set (write only)                ",
        "VECTOR       [4:0] highest pending [31] valid         ",
        "MASKED       pending AND enabled                      "), 7)
    say(" WDT @ 0x2000")
    dump(WDT, strings(
        "ID           \"WDOG\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(WDT + 0x10, strings(
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
            "ID           \"GPIO\" (ASCII)                           ",
            "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
            "DATE         BCD mm/dd/yyyy of that change            "), 3)
        dump(GPIO0 + (b << 12) + 0x10, strings(
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
            "ID           \"UART\" (ASCII)                           ",
            "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
            "DATE         BCD mm/dd/yyyy of that change            "), 3)
        dump(UART0 + (b << 12) + 0x10, strings(
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
            "ID           \"I2CM\" (ASCII)                          ",
            "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
            "DATE         BCD mm/dd/yyyy of that change            "), 3)
        dump(I2C0 + (b << 12) + 0x10, strings(
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
            "ID           \"SPIM\" (ASCII)                          ",
            "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
            "DATE         BCD mm/dd/yyyy of that change            "), 3)
        dump(SPI0 + (b << 12) + 0x10, strings(
            "CTRL         [0] en [1] cpol [2] cpha [15:8] cs       ",
            "DIV          SCLK half period = DIV + 1 clocks        ",
            "WORD_LEN     bits per word                            ",
            "STATUS       [0] busy [1] overrun [31:16] rx level    "), 4)
        dump_port(SPI0 + (b << 12))
        b += 1
    say(" FLASH @ 0xC000")
    dump(FLASH, strings(
        "ID           \"SPFL\" (ASCII)                          ",
        "VERSION      ASCII \"d.dd\", +0.01 per source change    ",
        "DATE         BCD mm/dd/yyyy of that change            "), 3)
    dump(FLASH + 0x10, strings(
        "CMD          last command: opcode, addr, dummy, dir   ",
        "ADDR         24-bit flash address                     ",
        "LEN          data bytes                               ",
        "CLKDIV       SCLK half period in clocks               ",
        "STATUS       [0] busy [1] done [2] command error      ",
        "IRQ_EN       [0] done interrupt                       "), 6)
    dump_port(FLASH)
