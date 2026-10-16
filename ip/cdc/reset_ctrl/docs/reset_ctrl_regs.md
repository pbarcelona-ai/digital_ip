# reset_ctrl register map

Reset controller: software reset, hold time, status, reset event count.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "RSTC" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | WO | 0x00000000 | write 1: software reset of the reset outputs (self clearing) |
| 0x14 | HOLD | RW | `HOLD_RST` | clocks the reset outputs stay asserted after a request |
| 0x18 | STATUS | CMD | 0x00000000 | status; write 1 to [1] to clear EVENT |
| 0x1C | EVENT_COUNT | RO | 0x00000000 | resets counted |

### STATUS (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | ACTIVE | reset output 0 asserted |
| 1 | EVENT | a reset happened (W1C) |
