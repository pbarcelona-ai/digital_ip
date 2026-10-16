# usb_fs_sie register map

USB full-speed serial interface engine: control, status, packet counters, bit period.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "USBF" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000003 | control |
| 0x14 | STATUS | CMD | 0x00000000 | status; write 1 to [1:0] to clear those flags |
| 0x18 | RX_GOOD | RO | 0x00000000 | packets received without errors |
| 0x1C | RX_BAD | RO | 0x00000000 | packets received with errors |
| 0x20 | TX_PKTS | RO | 0x00000000 | packets sent |
| 0x24 | BIT_PERIOD | RO | 0x00000000 | clocks per bit, 8.8 fixed point (CLK_HZ / 12 MHz) |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | ENABLE | 1: engine enabled |
| 1 | PULLUP | 1: D+ pull-up on (device attached) |

### STATUS (0x14)

| Bits | Field | Description |
|---|---|---|
| 0 | BUS_RESET | bus reset seen (W1C) |
| 1 | RX_OVERFLOW | received byte dropped (W1C) |
| 2 | TX_BUSY | transmitting |
| 3 | RX_ACTIVE | receiving |
| 9:8 | LINE | line state D+ / D- |
