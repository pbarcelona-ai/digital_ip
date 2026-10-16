# watchdog register map

Watchdog timer: prescaler, timeout, pre-timeout interrupt, window, keyed kick, lock.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "WDOG" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | CMD | 0x00000000 | control (EN and LOCK are ignored once LOCK is set) |
| 0x14 | TIMEOUT | RW | 0x000003E8 | reset after this many ticks without a kick |
| 0x18 | PRESCALE | RW | 0x00000000 | clock cycles per tick - 1 |
| 0x1C | PRETIMEOUT | RW | 0x00000000 | pre-timeout interrupt after this many ticks (0: off) |
| 0x20 | WINDOW_OPEN | RW | 0x00000000 | earliest legal kick, ticks (window mode) |
| 0x24 | KICK | WO | 0x00000000 | write 0x5AFEC0DE to restart the count (other values: bad key) |
| 0x28 | STATUS | CMD | 0x00000000 | flags, write 1 to clear |
| 0x2C | COUNT | RO | 0x00000000 | current tick count |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: watchdog running |
| 1 | WINDOW_EN | 1: a kick before WINDOW_OPEN is early (reset) |
| 2 | LOCK | 1: EN can no longer be changed (until reset) |

### STATUS (0x28)

| Bits | Field | Description |
|---|---|---|
| 0 | PRETIMEOUT | pre-timeout reached (interrupt) |
| 1 | EXPIRED | timeout reached (reset) |
| 2 | EARLY | kick before WINDOW_OPEN |
| 3 | BAD_KEY | kick with a wrong key |
