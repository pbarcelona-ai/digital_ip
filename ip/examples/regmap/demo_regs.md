# demo_regs register map

Example register map used to test the generator.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | 0x00000000 | Block identifier |
| 0x04 | CTRL | RW | 0x00000010 | Control |
| 0x08 | STATUS | W1C | 0x00000000 | Sticky status |
| 0x0C | THRESH | RW | 0x00000100 | Threshold |
| 0x10 | COUNT | RO | 0x00000000 | Live counter |
| 0x14 | TRIG | W1S | 0x00000000 | Software trigger bits, hardware clears when served |

### ID (0x00)

| Bits | Field | Description |
|---|---|---|
| 31:0 | VALUE | Constant supplied by hardware |

### CTRL (0x04)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | Enable |
| 3:1 | MODE | Operating mode |
| 15:8 | DIV | Clock divider |

### STATUS (0x08)

| Bits | Field | Description |
|---|---|---|
| 0 | DONE | Operation done |
| 1 | ERR | Error |

### TRIG (0x14)

| Bits | Field | Description |
|---|---|---|
| 0 | GO | Start |
