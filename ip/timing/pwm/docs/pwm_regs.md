# pwm register map

PWM timer: control, period, prescaler, dead time, output inversion, duty per channel.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "PWMT" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | control |
| 0x14 | PERIOD | RW | 0x00000063 | counter top |
| 0x18 | PRESCALE | RW | 0x00000000 | clock cycles per count - 1 |
| 0x1C | DEADTIME | RW | 0x00000000 | dead time in clocks (complementary mode) |
| 0x20 | INVERT | RW | 0x00000000 | output inversion per channel |
| 0x24 + 4 i (i < CHANNELS) | DUTY | RW | 0x00000000 | duty of channel n (loaded at the period start) |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | 1: counting |
| 1 | CENTER | 1: centre aligned (up / down) |
| 2 | COMPLEMENTARY | 1: complementary outputs with dead time |
