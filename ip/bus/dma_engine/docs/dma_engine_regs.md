# dma_engine register map

Memory to memory DMA: start control, source, destination, length, status.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "DMAE" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | control |
| 0x14 | SRC | RW | 0x00000000 | source address (4-byte aligned) |
| 0x18 | DST | RW | 0x00000000 | destination address (4-byte aligned) |
| 0x1C | LEN | RW | 0x00000000 | bytes to copy (multiple of 4, not 0) |
| 0x20 | STATUS | CMD | 0x00000000 | status; done and error write 1 to clear |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | START | write 1: start the copy |
| 1 | IRQ_EN | irq_o follows DONE |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | copy running |
| 8 | DONE | copy finished (W1C) |
| 9 | ERROR | bad length or bus error (W1C) |
