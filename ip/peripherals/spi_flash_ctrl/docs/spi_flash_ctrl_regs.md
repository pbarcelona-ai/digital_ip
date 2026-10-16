# spi_flash_ctrl register map

SPI NOR flash controller: generic command, address, length, clock divider, status, interrupt enable.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "SPFL" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CMD | RW | 0x00000000 | write starts a command (ignored and CMD_ERR while busy); reads back the last one |
| 0x14 | ADDR | RW | 0x00000000 | flash address (3 bytes) |
| 0x18 | LEN | RW | 0x00000000 | data bytes (0..65535) |
| 0x1C | CLKDIV | RW | 0x00000004 | sclk half period in clocks (minimum 3) |
| 0x20 | STATUS | CMD | 0x00000000 | status; write 1 to [2:1] to clear those flags |
| 0x24 | IRQ_EN | RW | 0x00000000 | [0] irq_o = DONE |

### CMD (0x10)

| Bits | Field | Description |
|---|---|---|
| 7:0 | OPCODE | flash opcode |
| 8 | ADDR_EN | send the 3 address bytes |
| 15:12 | DUMMY | dummy bytes after the address |
| 16 | READ_DATA | LEN data bytes read to m_axis |
| 17 | WRITE_DATA | LEN data bytes written from s_axis |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | command in progress |
| 1 | DONE | command finished (sticky, W1C) |
| 2 | CMD_ERR | CMD written while busy (sticky, W1C) |
