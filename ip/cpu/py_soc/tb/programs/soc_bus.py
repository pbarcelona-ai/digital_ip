"""py_soc bus and interrupt test firmware (the cocotb system test tb/python/py_soc_tb.py, case "bus"):
  EXT window (EXT_EN = 1)  words at the bottom and the top of the window, read back
  data RAM                 an array of squares written and summed
  external interrupts      ext_irq_i[3:0] (intc sources 12-15) as edge sources: the testbench pulses them
                           (one pulse on two sources at once), the handler reads VECTOR until no source is
                           left, clears each PENDING bit; the main program sleeps in wait_irq()
  SYSCTL timer             a compare 500 clocks ahead, wait_irq() until its interrupt
  unmapped address         a read of 0x2_0000: DECERR, the core stops with TRAP_BUS
The testbench compares the globals and the trap."""
from machine import mem32          # ignored by pyc: mem32 is native

from py_soc_map_pkg import *       # SYSCTL_BASE, INTC_BASE, EXT_BASE, RAM_BASE ... (pyc.py -I src)

INTC_ENABLE = 0x10
INTC_EDGE_TYPE = 0x14
INTC_PENDING = 0x1C
INTC_VECTOR = 0x24
VALID = 0x80000000
CYCLES = 0x18
TIMER_CMP = 0x2C
TIMER_CTRL = 0x30
TIMER_STATUS = 0x34
EXT_IRQS = 0xF000                  # intc sources 12-15
IRQ_TIMER = 1 << 16
N_EDGES = 6                        # the testbench's pulses: 4 single, one on two sources

errors = 0
stage = 0
ext_count = 0
ext_bits = 0
timer_hits = 0
vec_sum = 0
squares = 0


def isr():
    global ext_count, ext_bits, timer_hits, vec_sum
    v = mem32[INTC_BASE + INTC_VECTOR]
    while v & VALID:
        n = v & 31
        vec_sum += n
        if n == 16:
            mem32[SYSCTL_BASE + TIMER_STATUS] = 1  # write 1 to clear REACHED (a level source)
            timer_hits += 1
        else:
            mem32[INTC_BASE + INTC_PENDING] = 1 << n
            ext_bits |= 1 << n
            ext_count += 1
        v = mem32[INTC_BASE + INTC_VECTOR]


# 1. EXT window: bottom and top words
mem32[EXT_BASE] = 0x12345678
mem32[EXT_BASE + 0xFFFC] = 0x9ABCDEF0
if mem32[EXT_BASE] != 0x12345678:
    errors += 1
if mem32[EXT_BASE + 0xFFFC] != 0x9ABCDEF0:
    errors += 1

# 2. Data RAM: squares 0..63 written and summed
i = 0
while i < 64:
    mem32[RAM_BASE + 4 * i] = i * i
    i += 1
i = 0
while i < 64:
    squares += mem32[RAM_BASE + 4 * i]
    i += 1
if squares != 85344:
    errors += 1

# 3. External edge interrupts, the main program asleep in wait_irq()
mem32[INTC_BASE + INTC_EDGE_TYPE] = EXT_IRQS
mem32[INTC_BASE + INTC_ENABLE] = EXT_IRQS | IRQ_TIMER
irq_handler(isr)
irq_enable()
stage = 1
while ext_count < N_EDGES:
    wait_irq()

# 4. SYSCTL timer: a compare 500 clocks ahead
mem32[SYSCTL_BASE + TIMER_CTRL] = 1
mem32[SYSCTL_BASE + TIMER_CMP] = mem32[SYSCTL_BASE + CYCLES] + 500
while timer_hits < 1:
    wait_irq()
stage = 2

# 5. An unmapped address: DECERR, TRAP_BUS (the program ends here)
d = mem32[0x20000]
errors += 1
