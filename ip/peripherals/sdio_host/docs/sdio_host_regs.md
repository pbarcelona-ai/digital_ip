# sdio_host register map

SD / SDIO host: command, argument, responses, status, clock and bus control, block size, timeout, interrupt enables.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "SDIO" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CMD | RW | 0x00000000 | a write starts the command; reads back the last one |
| 0x14 | ARG | RW | 0x00000000 | command argument |
| 0x18 + 4 i (i < 4) | RESP | RO | 0x00000000 | response: short in RESP[0], long 127..0 in RESP[3]..RESP[0] |
| 0x28 | STATUS | CMD | 0x00000000 | status; write 1 to clear bits 1-7 |
| 0x2C | CTRL | RW | 0x00000002 | SD clock and bus |
| 0x30 | BLKSIZE | RW | 0x00000200 | block size in bytes (1..BUF_BYTES) |
| 0x34 | TIMEOUT | RW | 0x000186A0 | data / busy timeout in SD clocks |
| 0x38 | IRQ_EN | RW | 0x00000000 | bit n enables STATUS bit n + 1 for irq_o |

### CMD (0x10)

| Bits | Field | Description |
|---|---|---|
| 5:0 | INDEX | command index |
| 7:6 | RESP | response: 0 none, 1 short 48 bit, 2 long 136 bit |
| 9:8 | DIR | data: 0 none, 1 read block, 2 write block |
| 10 | NO_CRC | 1: no CRC7 check of the response (R3 / R7) |

### STATUS (0x28)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | command or data in progress |
| 1 | CMD_DONE | command finished |
| 2 | DAT_DONE | data block finished |
| 3 | CMD_TIMEOUT | no response |
| 4 | CMD_CRC_ERR | response CRC7 error |
| 5 | DAT_CRC_ERR | data CRC16, end bit or CRC status error |
| 6 | DAT_TIMEOUT | data or busy timeout |
| 7 | BUF_ERR | bad BLKSIZE, write without a full buffer, or command while busy |

### CTRL (0x2C)

| Bits | Field | Description |
|---|---|---|
| 15:0 | HALF_PERIOD | SD clock half period in system clocks (minimum 1) |
| 16 | BUS4 | 1: 4-bit data bus |
| 17 | CLK_EN | 1: SD clock running |
