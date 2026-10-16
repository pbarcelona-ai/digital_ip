# spi_master register map

SPI master: mode and chip select, SCLK divider, word length and status.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "SPIM" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | mode and chip select |
| 0x14 | DIV | RW | `DIV_RST` | SCLK half period = DIV + 1 clocks |
| 0x18 | WORD_LEN | RW | 0x00000008 | bits per word (1..DATA_W) |
| 0x1C | STATUS | CMD | 0x00000000 | status; write 1 to [1] to clear the overrun flag |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: master enabled |
| 1 | CPOL | SCLK idle level |
| 2 | CPHA | 1: sample on the second edge |
| 3 | LSB_FIRST | 1: least significant bit first |
| 15:8 | CS_SELECT | chip select driven low for the bursts |

### STATUS (0x1C)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | transfer in progress |
| 1 | RX_OVERRUN | a received word was dropped, receive FIFO full (W1C) |
| 31:16 | RX_LEVEL | words in the receive FIFO |
