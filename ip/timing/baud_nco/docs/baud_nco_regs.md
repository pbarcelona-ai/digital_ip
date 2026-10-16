# baud_nco register map

Baud-rate / sine NCO: control, frequency control word, phase offset, gain, status, tick counter.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "BNCO" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | CMD | 0x00000000 | control (reads [2] as 0) |
| 0x14 | FCW | RW | `FCW_RST` | frequency control word: phase step per clock (2^PHASE_W = one turn) |
| 0x18 | PHASE_OFF | RW | 0x00000000 | phase offset of the sine output |
| 0x1C | GAIN | RW | 0x00007FFF | sine amplitude |
| 0x20 | STATUS | RO | 0x00000000 | status |
| 0x24 | TICK_COUNT | CMD | 0x00000000 | baud ticks counted; a write clears it |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: NCO running (reset 1) |
| 1 | STREAM_EN | 1: samples on the AXI-Stream master |
| 2 | PHASE_RST | write 1: phase back to 0 (self clearing) |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | NCO running |
| 1 | TVALID | a sample is offered on the stream |
