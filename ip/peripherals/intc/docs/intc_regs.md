# intc register map

Interrupt controller: enable, edge / level type, polarity, pending, software set, vector.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "INTC" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | ENABLE | RW | 0x00000000 | interrupt enable per source |
| 0x14 | EDGE_TYPE | RW | 0x00000000 | 1 = edge source (latched in PENDING), 0 = level |
| 0x18 | ACTIVE_LOW | RW | 0x00000000 | 1 = active-low source |
| 0x1C | PENDING | CMD | 0x00000000 | pending sources; write 1 to clear latched (edge) bits |
| 0x20 | SOFT_SET | WO | 0x00000000 | write 1s: set those sources pending (software interrupt) |
| 0x24 | VECTOR | RO | 0x00000000 | highest-priority (lowest index) pending enabled source |
| 0x28 | MASKED | RO | 0x00000000 | PENDING AND ENABLE |

### VECTOR (0x24)

| Bits | Field | Description |
|---|---|---|
| 4:0 | ID | source number |
| 31 | VALID | a source is pending and enabled |
