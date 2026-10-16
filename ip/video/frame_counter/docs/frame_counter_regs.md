# frame_counter register map

Frame counters with interrupts and an event log.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "FCNT" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x18 | IRQ_EN | RW | 0x00000000 | interrupt enable per channel |
| 0x1C | STATUS | W1C | 0x00000000 | marker seen per channel (interrupt while enabled); write 1 to clear |
| 0x20 | CLEAR | WO | 0x00000000 | write 1s: clear COUNT[i] |
| 0x24 | EVENT | RO | 0x00000000 | oldest logged event |
| 0x28 | EVENT_TIME | RO | 0x00000000 | timestamp of that event (TIME ticks) |
| 0x2C | EVENT_POP | WO | 0x00000000 | log control |
| 0x30 + 4 i (i < NCH) | COUNT | RO | 0x00000000 | frames counted by channel i |
| 0x50 | TIME | RO | 0x00000000 | timestamp now (ticks of TS_DIV clocks) |
| 0x54 | EV_EN | RW | 0x00000000 | channels logged in the event log |

### EVENT (0x24)

| Bits | Field | Description |
|---|---|---|
| 31 | VALID | an event is logged |
| 30 | OVERFLOW | events lost (log was full) |
| 26:24 | CHANNEL | channel of the marker |
| 23:0 | COUNT | the channel's count after the marker |

### EVENT_POP (0x2C)

| Bits | Field | Description |
|---|---|---|
| 0 | POP | 1: remove the oldest event |
| 1 | OVF_CLR | 1: clear the overflow flag |
