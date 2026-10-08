"""py_soc self-test firmware.

Exercises every peripheral, with receive both polled and interrupt driven:
  GPIO0 -> GPIO1 loopback, GPIO2 edge interrupts
  UART0 -> UART1 polled,   UART1 -> UART0 16-byte burst through the TX
                           FIFO (no TX polling), interrupt driven receive
  SPI0 loopback polled,    SPI1 loopback interrupt driven
  I2C0 write/read polled,  I2C1 read interrupt driven
  flash JEDEC ID polled,   flash read of this program's boot image
                           header, interrupt driven
  watchdog serviced from its pre-timeout interrupt, then allowed to expire
  function calls: recursion, helpers shared by main code and the handler
  reset cause: after the watchdog reboot the firmware halts with it
The testbench watches the `stage` and result globals.
"""
from machine import mem32          # ignored by pyc: mem32 is native

# ---------------- address map ----------------
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
UART0_D = UART0 + 0x100            # py_stream_port data ports
UART1_D = UART1 + 0x100
I2C0_D = I2C0 + 0x100
I2C1_D = I2C1 + 0x100
SPI0_D = SPI0 + 0x100
SPI1_D = SPI1 + 0x100
FLASH_D = FLASH + 0x100

# data port
TXDATA = 0x00
RXDATA = 0x04
PSTATUS = 0x08
IRQ_EN = 0x0C
RX_VALID = 1 << 31
LAST = 1 << 24
TX_READY = 2
TX_OVF = 4
TX_LEVEL_SHIFT = 20

# system control
RESET_CAUSE = 0x00
CYCLES = 0x08
CAUSE_EXT = 1
CAUSE_WDT = 2

# interrupt controller
INTC_ENABLE = 0x00
INTC_MASKED = 0x18
IRQ_UART0 = 1 << 0
IRQ_UART1 = 1 << 1
IRQ_I2C0 = 1 << 2
IRQ_I2C1 = 1 << 3
IRQ_SPI0 = 1 << 4
IRQ_SPI1 = 1 << 5
IRQ_GPIO2 = 1 << 8
IRQ_WDT = 1 << 9
IRQ_FLASH_D = 1 << 11

# GPIO
G_OUT = 0x00
G_DIR = 0x04
G_IN = 0x08
G_SET = 0x0C
G_CLEAR = 0x10
G_TOGGLE = 0x14
G_INT_EN = 0x18
G_RISE_EN = 0x1C
G_INT_STATUS = 0x24

# SPI
S_CTRL = 0x00
S_DIV = 0x04
S_WORD_LEN = 0x08

# I2C
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

# SPI flash controller
F_CMD = 0x00
F_ADDR = 0x04
F_LEN = 0x08
F_STATUS = 0x10
F_READ_DATA = 1 << 16
F_ADDR_EN = 1 << 8
F_DONE = 2

# watchdog
W_CTRL = 0x00
W_TIMEOUT = 0x04
W_PRESCALE = 0x08
W_PRETIMEOUT = 0x0C
W_KICK = 0x14
WDT_KEY = 0x5AFEC0DE

TMO = 20000
GPIO_PATTERN = 0xA5A5F00F
GPIO_EXPECT = ((GPIO_PATTERN | 0x0FF0) & ~0x80000001) ^ 0x50000000

# ---------------- state shared with the interrupt handler ----------------
errors = 0
stage = 0
u0_count = 0
u0_sum = 0
spi1_count = 0
spi1_sum = 0
i2c1_count = 0
i2c1_sum = 0
gpio_edges = 0
gpio_bits = 0
wdt_pre = 0
wdt_feed = 1
flash_count = 0
flash_word = 0


# ---------------- functions ----------------
def wait_set(addr, mask):
    """Poll until a register bit is set; True if it was set before TMO polls."""
    t = 0
    while not mem32[addr] & mask and t < TMO:
        t += 1
    return t < TMO


def tri(n):
    if n == 0:
        return 0
    return n + tri(n - 1)


def rx_byte(port):
    """Pop one byte from a data port: the byte, or -1 if the RX FIFO is empty."""
    d = mem32[port + RXDATA]
    if d & RX_VALID:
        return d & 0xFF
    return -1


def isr():
    global u0_count, u0_sum, spi1_count, spi1_sum, i2c1_count, i2c1_sum
    global gpio_edges, gpio_bits, wdt_pre, flash_count, flash_word
    pending = mem32[INTC + INTC_MASKED]
    if pending & IRQ_UART0:                   # drain the receive stream
        while True:
            b = rx_byte(UART0_D)
            if b < 0:
                break
            u0_sum += b
            u0_count += 1
    if pending & IRQ_SPI1:
        while True:
            d = mem32[SPI1_D + RXDATA]
            if not d & RX_VALID:
                break
            spi1_sum += d & 0xFFFF
            spi1_count += 1
    if pending & IRQ_I2C1:
        while True:
            b = rx_byte(I2C1_D)
            if b < 0:
                break
            i2c1_sum += b
            i2c1_count += 1
    if pending & IRQ_FLASH_D:                 # little-endian word assembly
        while True:
            d = mem32[FLASH_D + RXDATA]
            if not d & RX_VALID:
                break
            flash_word = (flash_word >> 8) | ((d & 0xFF) << 24)
            flash_count += 1
    if pending & IRQ_GPIO2:
        s = mem32[GPIO2 + G_INT_STATUS]
        mem32[GPIO2 + G_INT_STATUS] = s       # write-1-to-clear
        gpio_bits |= s
        gpio_edges += 1
    if pending & IRQ_WDT:
        wdt_pre += 1
        if wdt_feed:
            mem32[WDT + W_KICK] = WDT_KEY
        else:                                  # stop servicing: let it expire
            mem32[INTC + INTC_ENABLE] &= ~IRQ_WDT


# ---------------- main ----------------
cause = mem32[SYSCTL + RESET_CAUSE]
mem32[SYSCTL + RESET_CAUSE] = CAUSE_EXT | CAUSE_WDT     # write 1 to clear
if cause & CAUSE_WDT:                          # rebooted by the watchdog: report and stop
    halt(cause)

# 0. Function calls: recursion and a multi-argument helper
if tri(10) != 55:
    errors += 1
c0 = mem32[SYSCTL + CYCLES]
if mem32[SYSCTL + CYCLES] - c0 <= 0:           # the cycle counter runs
    errors += 1

mem32[INTC + INTC_ENABLE] = IRQ_UART0 | IRQ_SPI1 | IRQ_I2C1 | IRQ_GPIO2 | IRQ_WDT | IRQ_FLASH_D
irq_handler(isr)
irq_enable()

# 1. GPIO bank 0 drives bank 1 (looped on the board), full 32-bit values
stage = 1
mem32[GPIO0 + G_DIR] = 0xFFFFFFFF
mem32[GPIO0 + G_OUT] = GPIO_PATTERN
t = 0
while t < 4:                                   # input synchronizers
    t += 1
if mem32[GPIO1 + G_IN] != GPIO_PATTERN:
    errors += 1
mem32[GPIO0 + G_SET] = 0x0FF0
mem32[GPIO0 + G_CLEAR] = 0x80000001
mem32[GPIO0 + G_TOGGLE] = 0x50000000
t = 0
while t < 4:
    t += 1
if mem32[GPIO1 + G_IN] != GPIO_EXPECT:
    errors += 1

# 2. GPIO bank 2 rising-edge interrupts (testbench pulses pins 0 and 31)
mem32[GPIO2 + G_RISE_EN] = 0xFFFFFFFF
mem32[GPIO2 + G_INT_EN] = 0xFFFFFFFF
stage = 2
t = 0
while gpio_bits != 0x80000001 and t < TMO:
    t += 1
if gpio_bits != 0x80000001:
    errors += 1

# 3. UART0 -> UART1, receive polled
stage = 3
mem32[UART0_D + TXDATA] = 0x48
d = 0
t = 0
while not d & RX_VALID and t < TMO:
    d = mem32[UART1_D + RXDATA]
    t += 1
if d != RX_VALID | 0x48:
    errors += 1

# 4. UART1 -> UART0: 16-byte burst into the TX FIFO, receive interrupt driven
stage = 4
mem32[UART0_D + IRQ_EN] = 1
i = 0
while i < 16:                                  # no TX_READY polling: the FIFO holds them
    mem32[UART1_D + TXDATA] = 0x30 + i
    i += 1
if mem32[UART1_D + PSTATUS] >> TX_LEVEL_SHIFT == 0:   # still queued behind a 5 us/byte line
    errors += 1
if mem32[UART1_D + PSTATUS] & TX_OVF:
    errors += 1
t = 0
while u0_count < 16 and t < TMO:
    t += 1
if u0_count != 16 or u0_sum != 16 * 0x30 + 120:
    errors += 1

# 5. SPI0 loopback (MOSI -> MISO), receive polled, 16-bit words
stage = 5
mem32[SPI0 + S_DIV] = 2
mem32[SPI0 + S_WORD_LEN] = 16
mem32[SPI0 + S_CTRL] = 1
mem32[SPI0_D + TXDATA] = LAST | 0xBEEF
d = 0
t = 0
while not d & RX_VALID and t < TMO:
    d = mem32[SPI0_D + RXDATA]
    t += 1
if d & 0xFFFF != 0xBEEF:
    errors += 1

# 6. SPI1 loopback on chip select 1, receive interrupt driven
stage = 6
mem32[SPI1_D + IRQ_EN] = 1
mem32[SPI1 + S_DIV] = 2
mem32[SPI1 + S_WORD_LEN] = 16
mem32[SPI1 + S_CTRL] = (1 << 8) | 1
mem32[SPI1_D + TXDATA] = 0x1111
mem32[SPI1_D + TXDATA] = 0x2222
mem32[SPI1_D + TXDATA] = LAST | 0x3333
t = 0
while spi1_count < 3 and t < TMO:
    t += 1
if spi1_count != 3 or spi1_sum != 0x6666:
    errors += 1

# 7. I2C0: write 0xAA 0x55 at pointer 0x10 of slave 0x50, read back polled
stage = 7
mem32[I2C0_D + TXDATA] = 0x10
mem32[I2C0_D + TXDATA] = 0xAA
mem32[I2C0_D + TXDATA] = 0x55
mem32[I2C0 + I_ADDR] = 0x50
mem32[I2C0 + I_LEN] = 3
mem32[I2C0 + I_STATUS] = I_CLEAR
mem32[I2C0 + I_CTRL] = I_EN | I_START
if not wait_set(I2C0 + I_STATUS, I_DONE):
    errors += 1
if mem32[I2C0 + I_STATUS] & I_NACK:
    errors += 1
mem32[I2C0_D + TXDATA] = 0x10                  # set the pointer back
mem32[I2C0 + I_LEN] = 1
mem32[I2C0 + I_STATUS] = I_CLEAR
mem32[I2C0 + I_CTRL] = I_EN | I_START
if not wait_set(I2C0 + I_STATUS, I_DONE):
    errors += 1
mem32[I2C0 + I_LEN] = 2
mem32[I2C0 + I_STATUS] = I_CLEAR
mem32[I2C0 + I_CTRL] = I_EN | I_START | I_READ
if not wait_set(I2C0 + I_STATUS, I_DONE):
    errors += 1
if mem32[I2C0_D + RXDATA] != RX_VALID | 0xAA:
    errors += 1
if mem32[I2C0_D + RXDATA] != RX_VALID | LAST | 0x55:
    errors += 1
if mem32[I2C0_D + PSTATUS] & TX_OVF:
    errors += 1

# 8. I2C1: read 4 bytes from slave 0x51, receive interrupt driven
stage = 8
mem32[I2C1_D + IRQ_EN] = 1
mem32[I2C1_D + TXDATA] = 0x00
mem32[I2C1 + I_ADDR] = 0x51
mem32[I2C1 + I_LEN] = 1
mem32[I2C1 + I_STATUS] = I_CLEAR
mem32[I2C1 + I_CTRL] = I_EN | I_START
if not wait_set(I2C1 + I_STATUS, I_DONE):
    errors += 1
mem32[I2C1 + I_LEN] = 4
mem32[I2C1 + I_STATUS] = I_CLEAR
mem32[I2C1 + I_CTRL] = I_EN | I_START | I_READ
t = 0
while i2c1_count < 4 and t < TMO:
    t += 1
if i2c1_count != 4 or i2c1_sum != 0x11 + 0x22 + 0x33 + 0x44:
    errors += 1

# 9. Flash JEDEC ID (9Fh), receive polled
stage = 9
mem32[FLASH + F_LEN] = 3
mem32[FLASH + F_STATUS] = F_DONE
mem32[FLASH + F_CMD] = F_READ_DATA | 0x9F
if not wait_set(FLASH + F_STATUS, F_DONE):
    errors += 1
if mem32[FLASH_D + RXDATA] != RX_VALID | 0xEF:
    errors += 1
if mem32[FLASH_D + RXDATA] != RX_VALID | 0x40:
    errors += 1
if mem32[FLASH_D + RXDATA] != RX_VALID | LAST | 0x17:
    errors += 1

# 10. Read this program's own boot image header back from flash, receive interrupt driven
stage = 10
mem32[FLASH_D + IRQ_EN] = 1
mem32[FLASH + F_ADDR] = 0
mem32[FLASH + F_LEN] = 4
mem32[FLASH + F_STATUS] = F_DONE
mem32[FLASH + F_CMD] = F_READ_DATA | F_ADDR_EN | 0x03
t = 0
while flash_count < 4 and t < TMO:
    t += 1
if flash_word != 0x31435950:                   # "PYC1"
    errors += 1

# 11. Watchdog: kicked from the pre-timeout interrupt three times, then left to expire
stage = 11
mem32[WDT + W_PRESCALE] = 9                    # one tick per 10 clocks
mem32[WDT + W_PRETIMEOUT] = 50
mem32[WDT + W_TIMEOUT] = 100
mem32[WDT + W_CTRL] = 1
t = 0
while wdt_pre < 3 and t < TMO:
    t += 1
if wdt_pre < 3:
    errors += 1
stage = 12                                     # results are final
wdt_feed = 0
while True:                                    # the watchdog resets the system
    pass
