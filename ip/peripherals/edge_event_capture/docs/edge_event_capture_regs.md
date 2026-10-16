# edge_event_capture register map

Edge event capture: enables, debounce, pending edges, counters, timestamp, interrupt enables.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "EDGE" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000001 | [0] capture enabled |
| 0x14 | RISE_EN | RW | 0x00000000 | rising edges captured per input |
| 0x18 | FALL_EN | RW | 0x00000000 | falling edges captured per input |
| 0x1C | DEBOUNCE | RW | 0x00000000 | clocks an input must be stable before its edge counts (0: none) |
| 0x20 | RISE_PEND | W1C | 0x00000000 | rising edges seen per input; write 1 to clear |
| 0x24 | FALL_PEND | W1C | 0x00000000 | falling edges seen per input; write 1 to clear |
| 0x28 | EVENT_COUNT | RO | 0x00000000 | clocks with at least one captured edge |
| 0x2C | TIMESTAMP | RO | 0x00000000 | free-running timestamp (TS_W bits) |
| 0x30 | DROP_COUNT | RO | 0x00000000 | event records lost (FIFO full) |
| 0x34 | IRQ_EN | RW | 0x00000000 | irq_o while a pending edge of an enabled input is set |
