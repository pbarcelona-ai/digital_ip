# quad_dec register map

Quadrature decoder: control and filter, position, velocity, window, status, error count, index position.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "QDEC" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000001 | control |
| 0x14 | POSITION | CMD | 0x00000000 | signed position (x4 counts); a write loads it |
| 0x18 | VELOCITY | RO | 0x00000000 | signed counts in the last window |
| 0x1C | WINDOW | RW | 0x000186A0 | velocity window, clocks |
| 0x20 | STATUS | CMD | 0x00000000 | status; write 1 to [2:1] to clear those flags |
| 0x24 | ERR_COUNT | RO | 0x00000000 | illegal transitions counted |
| 0x28 | INDEX_POS | RO | 0x00000000 | position at the last index edge |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: decoding |
| 1 | CLR_POS | write 1: position to 0 |
| 2 | INDEX_CLR | 1: the index edge clears the position |
| 3 | SWAP | 1: swap A and B |
| 15:8 | FILTER | input stability filter, clocks |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | DIR | direction of the last step (1 = up) |
| 1 | ERROR | illegal transition seen (W1C) |
| 2 | INDEX | index edge seen (W1C) |
