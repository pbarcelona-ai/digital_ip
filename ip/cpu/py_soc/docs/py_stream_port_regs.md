# py_stream_port register map

AXI4-Lite to AXI-Stream data port: TX FIFO writes, RX FIFO reads, FIFO status, interrupt enables.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "PORT" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | TXDATA | WO | 0x00000000 | pushed into the TX FIFO, or dropped with STATUS.TX_OVF set when it is full |
| 0x14 | RXDATA | RC | 0x00000000 | oldest received word; a read with VALID = 1 removes it from the RX FIFO |
| 0x18 | STATUS | CMD | 0x00000000 | FIFO status; write 1 to [2] to clear TX_OVF |
| 0x1C | IRQ_EN | RW | 0x00000000 | irq_o while an enabled condition holds |

### TXDATA (0x10)

| Bits | Field | Description |
|---|---|---|
| 23:0 | DATA | data |
| 24 | LAST | tlast |

### RXDATA (0x14)

| Bits | Field | Description |
|---|---|---|
| 23:0 | DATA | data |
| 24 | LAST | tlast |
| 31 | VALID | 1: a word was read (0: the RX FIFO was empty) |

### STATUS (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | RX_VALID | RX FIFO not empty |
| 1 | TX_READY | TX FIFO not full |
| 2 | TX_OVF | a TXDATA write was dropped (W1C) |
| 3 | TX_EMPTY | TX FIFO empty |
| 19:8 | RX_LEVEL | words in the RX FIFO |
| 31:20 | TX_LEVEL | words in the TX FIFO |

### IRQ_EN (0x1C)

| Bits | Field | Description |
|---|---|---|
| 0 | RX_VALID | RX FIFO not empty |
| 1 | TX_READY | TX FIFO not full |
| 2 | TX_EMPTY | TX FIFO empty |
