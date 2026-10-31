# npu register map

INT8 neural-network accelerator: frame writer to DDR, command processor (64-byte layer descriptors), 64 x 64 MAC array, decode of detections (golden model: ip/ai/npu/model/npu_model.py).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "NPU8" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | RW | 0x00000000 | control |
| 0x14 | CMD | WO | 0x00000000 | write 1: start a run now (ignored while busy) |
| 0x18 | STATUS | RO | 0x00000000 | state |
| 0x1C | IRQ_EN | RW | 0x00000000 | interrupt enables |
| 0x20 | IRQ_STATUS | W1C | 0x00000000 | interrupt status; write 1 to clear |
| 0x24 | DESC_ADDR | RW | 0x00000000 | DDR address of the first layer descriptor |
| 0x28 | DET_ADDR | RW | 0x00000000 | DDR address of the detection list (16 bytes per detection) |
| 0x2C | DET_MAX | RW | 0x00000040 | most detections written |
| 0x30 | DET_COUNT | RO | 0x00000000 | detections written by the last run |
| 0x34 | FRAME_ADDR | RW | 0x00000000 | DDR address of the frame buffer (frame writer, INPUT operation) |
| 0x38 | FRAME_STRIDE | RW | 0x00000000 | bytes per frame buffer line |
| 0x3C | FRAME_SIZE | RW | 0x00000000 | frame size |
| 0x40 | LB_STEP | RW | 0x00000000 | letterbox: frame pixels per network input pixel, Q16 (bilinear scaling) |
| 0x44 | LB_OFFSET | RW | 0x00000000 | letterbox: top-left of the picture in the network input |
| 0x48 | LB_SIZE | RW | 0x00000000 | letterbox: picture size in the network input |
| 0x4C | LB_INV | RW | 0x00000000 | decode: frame pixels per network input pixel, Q16 (detections in frame pixels) |
| 0x50 | CYCLES | RO | 0x00000000 | clocks of the last run |
| 0x54 | RUNS | RO | 0x00000000 | runs completed |
| 0x58 | LB2_STEP | RW | 0x00000000 | second letterbox (INPUT / DECODE with descriptor flag BANK2: the low-resolution pass for large objects): as LB_STEP |
| 0x5C | LB2_OFFSET | RW | 0x00000000 | second letterbox: as LB_OFFSET |
| 0x60 | LB2_SIZE | RW | 0x00000000 | second letterbox: as LB_SIZE |
| 0x64 | LB2_INV | RW | 0x00000000 | second letterbox: as LB_INV |

### CTRL (0x10)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | on |
| 1 | AUTO | start a run on every frame the frame writer completes |
| 2 | WRITE | frame writer on: every input frame (RGB888) to FRAME_ADDR, FRAME_STRIDE bytes per line |

### CMD (0x14)

| Bits | Field | Description |
|---|---|---|
| 0 | START | start |

### STATUS (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | BUSY | a run in progress |
| 1 | FRAME | a frame was written since the last run started |

### IRQ_EN (0x1C)

| Bits | Field | Description |
|---|---|---|
| 0 | DONE | run done |
| 1 | ERROR | bad descriptor |

### IRQ_STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | DONE | run done |
| 1 | ERROR | bad descriptor (unknown operation) |

### FRAME_SIZE (0x3C)

| Bits | Field | Description |
|---|---|---|
| 15:0 | WIDTH | pixels |
| 31:16 | HEIGHT | lines |

### LB_OFFSET (0x44)

| Bits | Field | Description |
|---|---|---|
| 15:0 | X | column |
| 31:16 | Y | line |

### LB_SIZE (0x48)

| Bits | Field | Description |
|---|---|---|
| 15:0 | WIDTH | pixels |
| 31:16 | HEIGHT | lines |

### LB2_OFFSET (0x5C)

| Bits | Field | Description |
|---|---|---|
| 15:0 | X | column |
| 31:16 | Y | line |

### LB2_SIZE (0x60)

| Bits | Field | Description |
|---|---|---|
| 15:0 | WIDTH | pixels |
| 31:16 | HEIGHT | lines |
