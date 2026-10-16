# uart register map

UART control, baud rate (fractional), status and error count.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "UART" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000003 | line settings |
| 0x14 | FCW | RW | `FCW_RST` | baud generator frequency control word (16 x baud / clock x 2^32) |
| 0x18 | STATUS | CMD | 0x00000000 | state and sticky errors (write 1 to clear the errors) |
| 0x1C | ERR_CNT | RO | 0x00000000 | frames received with an error |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | TX_EN | transmitter on |
| 1 | RX_EN | receiver on |
| 2 | PAR_EN | parity on |
| 3 | PAR_ODD | odd parity |
| 4 | STOP2 | two stop bits |
| 5 | LOOPBACK | internal loopback |
| 7:6 | BITS | data bits: 0 = 8, 1 = 7, 2 = 6, 3 = 5 |

### STATUS (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | TX_BUSY | transmitting |
| 1 | RX_BUSY | receiving |
| 2 | RX_AVAIL | received data available |
| 8 | FRAME_ERR | framing error (W1C) |
| 9 | PARITY_ERR | parity error (W1C) |
| 10 | OVERRUN | receive FIFO overrun (W1C) |
| 30:16 | RX_LEVEL | receive FIFO level |
