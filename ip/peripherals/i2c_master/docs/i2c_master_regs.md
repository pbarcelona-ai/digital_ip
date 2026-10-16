# i2c_master register map

I2C master: transaction control, target address, length, SCL divider and status.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "I2CM" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | CMD | 0x00000000 | transaction control; reads EN / READ / NO_STOP as stored, START reads 0 |
| 0x14 | ADDR | RW | 0x00000000 | 7-bit target address |
| 0x18 | LEN | RW | 0x00000000 | bytes to transfer |
| 0x1C | DIV | RW | `DIV_RST` | phase clocks - 1: f_scl = f_clk / (4 * (DIV + 1)) |
| 0x20 | STATUS | CMD | 0x00000000 | status; write 1s to [3:1] to clear those flags |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: master enabled |
| 1 | START | write 1: start the transaction (a command, reads 0) |
| 2 | READ | 1: read, 0: write (bytes from the AXI-Stream slave) |
| 3 | NO_STOP | 1: no STOP at the end (repeated START next) |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | transaction in progress |
| 1 | DONE | transaction finished (W1C; also cleared by START) |
| 2 | NACK | target did not acknowledge (W1C) |
| 3 | ARB_LOST | arbitration lost (W1C) |
| 31:16 | RX_LEVEL | bytes in the receive FIFO |
