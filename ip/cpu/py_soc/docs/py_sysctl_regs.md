# py_sysctl register map

py_soc system control: reset cause, boot status, cycle counter, SoC ID, core logic reset, clock enables, timer compare interrupt.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "SCTL" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | RESET_CAUSE | CMD | 0x00000000 | cause of the last reset (sticky across system resets, cleared by the external reset only); write 1 to clear |
| 0x14 | BOOT_STATUS | RO | 0x00000000 | boot loader result |
| 0x18 | CYCLES | RO | 0x00000000 | free-running clock counter (wraps at 2**32) |
| 0x1C | SOC_ID | RO | 0x00000000 | SoC ID 0x50590100 ("PY", version 1.0) |
| 0x20 | CORE_RESET | RW | 0x00000000 | 1 = release the reset of the logic outside py_soc (cleared by every system reset) |
| 0x24 | CLK_EN | RW | `CLK_EN_RST[NCLK-1:0]` | clock generator output enables |
| 0x28 | CLK_STATUS | RO | 0x00000000 | clock generator status |
| 0x2C | TIMER_CMP | RW | 0x00000000 | timer compare: STATUS.REACHED is set when CYCLES reaches this value (CYCLES - TIMER_CMP < 2**31, wrap-safe); the CPU's timeouts and timed waits sleep on it |
| 0x30 | TIMER_CTRL | RW | 0x00000000 | timer interrupt |
| 0x34 | TIMER_STATUS | CMD | 0x00000000 | timer status (the logic's flag); write 1 to clear |

### RESET_CAUSE (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EXTERNAL | external reset (rst_n) |
| 1 | WATCHDOG | watchdog reset |

### BOOT_STATUS (0x14)

| Bits | Field | Description |
|---|---|---|
| 0 | DONE | boot done |
| 1 | ERROR | boot error |
| 6:4 | CODE | boot error code |

### CLK_STATUS (0x28)

| Bits | Field | Description |
|---|---|---|
| 0 | LOCKED | outputs locked (1 without a clock generator) |
| 1 | PRESENT | clock generator present |

### TIMER_CTRL (0x30)

| Bits | Field | Description |
|---|---|---|
| 0 | IRQ_EN | irq_o (timer_irq_o, intc source 16) while TIMER_STATUS.REACHED |

### TIMER_STATUS (0x34)

| Bits | Field | Description |
|---|---|---|
| 0 | REACHED | CYCLES reached TIMER_CMP: one-shot, armed by every TIMER_CMP write (which clears it), set in the clock CYCLES equals TIMER_CMP (in the clock after the write when it is already reached: CYCLES - TIMER_CMP < 2**31); write 1 to clear (a set in the same clock wins) |
