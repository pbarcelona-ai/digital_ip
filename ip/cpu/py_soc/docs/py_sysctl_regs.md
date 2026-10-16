# py_sysctl register map

py_soc system control: reset cause, boot status, cycle counter, SoC ID, core logic reset, clock enables.

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
