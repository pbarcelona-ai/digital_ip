# gpio register map

General purpose I/O: direction, output with atomic set / clear / toggle, synchronised inputs, edge interrupts.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "GPIO" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | OUT | CMD | 0x00000000 | output register: reads the pin output values, a write sets them all |
| 0x14 | DIR | RW | 0x00000000 | direction per pin, 1 = output (0 = input, pad high-Z) |
| 0x18 | IN | RO | 0x00000000 | pin levels (two-flop synchronised) |
| 0x1C | SET | WO | 0x00000000 | write 1s: set those OUT bits (atomic) |
| 0x20 | CLEAR | WO | 0x00000000 | write 1s: clear those OUT bits (atomic) |
| 0x24 | TOGGLE | WO | 0x00000000 | write 1s: invert those OUT bits (atomic) |
| 0x28 | INT_EN | RW | 0x00000000 | interrupt enable per pin (INT_STATUS bits that raise irq_o) |
| 0x2C | RISE_EN | RW | 0x00000000 | a rising edge of the pin sets INT_STATUS |
| 0x30 | FALL_EN | RW | 0x00000000 | a falling edge of the pin sets INT_STATUS |
| 0x34 | INT_STATUS | W1C | 0x00000000 | edges seen per pin; write 1 to clear |
