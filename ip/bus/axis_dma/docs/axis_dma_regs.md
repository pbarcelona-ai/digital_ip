# axis_dma register map

AXI-Stream DMA: start control, MM2S / S2MM address and length, status.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "ADMA" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | control |
| 0x14 | MM2S_ADDR | RW | 0x00000000 | MM2S source address (bytes) |
| 0x18 | MM2S_LEN | RW | 0x00000000 | MM2S length in bytes (multiple of 4, not 0) |
| 0x1C | S2MM_ADDR | RW | 0x00000000 | S2MM destination address (bytes) |
| 0x20 | S2MM_LEN | RW | 0x00000000 | S2MM length in bytes (multiple of 4, not 0) |
| 0x24 | STATUS | CMD | 0x00000000 | status; done and error bits write 1 to clear |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | MM2S_START | write 1: start a memory to stream transfer |
| 1 | S2MM_START | write 1: start a stream to memory transfer |
| 2 | IRQ_EN | irq_o on a done flag |

### STATUS (0x24)

| Bits | Field | Description |
|---|---|---|
| 0 | MM2S_BUSY | MM2S running |
| 1 | S2MM_BUSY | S2MM running |
| 8 | MM2S_DONE | MM2S finished (W1C) |
| 9 | S2MM_DONE | S2MM finished (W1C) |
| 10 | MM2S_ERR | MM2S bad length or bus error (W1C) |
| 11 | S2MM_ERR | S2MM bad length or bus error (W1C) |
