# ddr_ctrl register map

Generic DDR controller: statistics clear, status, and the statistics counters (32-bit, wrapping).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "DDRC" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | WO | 0x00000000 | [0] write 1: clear the statistics |
| 0x14 | STATUS | RO | 0x00000000 | [0] a burst active, [4:1] refreshes owed |
| 0x18 | RD_BEATS | RO | 0x00000000 | memory read beats (RD commands) |
| 0x1C | WR_BEATS | RO | 0x00000000 | memory write beats (WR commands) |
| 0x20 | ACTS | RO | 0x00000000 | ACT commands (row openings) |
| 0x24 | HITS | RO | 0x00000000 | memory beats issued without an ACT for the beat (row hits) |
| 0x28 | REFS | RO | 0x00000000 | REF commands |
| 0x2C | ERRS | RO | 0x00000000 | error bursts (SLVERR: size or burst type, DECERR: beyond the memory) |
