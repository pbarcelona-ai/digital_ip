# object_tracker register map

Object detector / measurement: bounding box, count and sums of the object pixels (luma threshold or colour ranges, run widths) in a search window, per frame.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "OTRK" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x18 | CTRL | RW | 0x00000000 | control |
| 0x1C | FRAME_SIZE | RW | 0x00000000 | frame size |
| 0x20 | THRESH | RW | 0x00000000 | luma threshold |
| 0x24 | WIN_X | RW | 0x00000000 | search window columns (inclusive, taken at the frame start) |
| 0x28 | WIN_Y | RW | 0x00000000 | search window lines |
| 0x2C | FRAMES | RO | 0x00000000 | frames measured |
| 0x30 | COUNT | RO | 0x00000000 | object pixels in the last frame (0: nothing found) |
| 0x34 | BOX_X | RO | 0x00000000 | object box columns of the last frame |
| 0x38 | BOX_Y | RO | 0x00000000 | object box lines |
| 0x3C | SUM_X | RO | 0x00000000 | sum of the object pixels' x (centroid = SUM_X / COUNT) |
| 0x40 | SUM_Y | RO | 0x00000000 | sum of their y |
| 0x44 | STATUS | RO | 0x00000000 | state |
| 0x48 | RUN | RW | 0x00000000 | run widths counted (a horizontal run of object pixels is judged when it ends) |
| 0x4C | Y_RANGE | RW | 0x0000FF00 | colour mode: luma Y = (R + 2G + B) / 4 range |
| 0x50 | CB_RANGE | RW | 0x0000FF00 | colour mode: Cb = 128 + (B - Y) / 2 range |
| 0x54 | CR_RANGE | RW | 0x0000FF00 | colour mode: Cr = 128 + (R - Y) / 2 range |
| 0x58 | SAT_MIN | RW | 0x00000000 | colour mode: lowest saturation |Cb - 128| + |Cr - 128| |
| 0x5C | BLOB_CFG | RW | 0x00000202 | blob grouping of the counted runs |
| 0x60 + 4 i (i < 28) | SCRATCH | RW | 0x00000000 | CPU scratch words (the firmware's tracking state of this detector's objects) |
| 0xD0 | RUN_B | RW | 0x00000000 | term B run widths counted (judged when a run ends, by its whole length) |
| 0x100 + 4 i (i < 8) | BLOB_X | RO | 0x00000000 | blob i columns at the end of the last frame (BLOB_N = 0: none) |
| 0x120 + 4 i (i < 8) | BLOB_Y | RO | 0x00000000 | blob i lines |
| 0x140 + 4 i (i < 8) | BLOB_N | RO | 0x00000000 | blob i pixels (0: no blob) |

### CTRL (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | enable |
| 1 | POL | luma mode, 1: object darker than THRESH |
| 2 | MODE | 0 luma threshold, 1 colour ranges (Y_RANGE, CB_RANGE, CR_RANGE, SAT_MIN) |
| 11:8 | MIN_RUN | shortest run counted when RUN.MIN_W = 0 (0 or 1: every pixel counts) |
| 13:12 | FEAT_A | term A: 0 the luma / colour test, 1 it or the motion feature, 2 it and the motion feature, 3 the motion feature |
| 14 | TERM_B | term B on: the edge feature, in runs of RUN_B (its own blob slots) |

### FRAME_SIZE (0x1C)

| Bits | Field | Description |
|---|---|---|
| 15:0 | WIDTH | width |
| 31:16 | HEIGHT | height |

### WIN_X (0x24)

| Bits | Field | Description |
|---|---|---|
| 15:0 | X0 | first |
| 31:16 | X1 | last |

### WIN_Y (0x28)

| Bits | Field | Description |
|---|---|---|
| 15:0 | Y0 | first |
| 31:16 | Y1 | last |

### BOX_X (0x34)

| Bits | Field | Description |
|---|---|---|
| 15:0 | X_MIN | min |
| 31:16 | X_MAX | max |

### BOX_Y (0x38)

| Bits | Field | Description |
|---|---|---|
| 15:0 | Y_MIN | min |
| 31:16 | Y_MAX | max |

### STATUS (0x44)

| Bits | Field | Description |
|---|---|---|
| 0 | IN_FRAME | in a frame |
| 1 | FULL_WIN | the window of the frame being measured is the whole frame |
| 15:8 | BLOB_LOST | runs of the last frame not grouped into a blob (every slot taken; saturates at 255) |
| 31:16 | FRAMES | FRAMES[15:0] |

### RUN (0x48)

| Bits | Field | Description |
|---|---|---|
| 11:0 | MIN_W | shortest run (0: CTRL.MIN_RUN) |
| 27:16 | MAX_W | longest run (0: no limit) |

### Y_RANGE (0x4C)

| Bits | Field | Description |
|---|---|---|
| 7:0 | MIN | lowest |
| 15:8 | MAX | highest |

### CB_RANGE (0x50)

| Bits | Field | Description |
|---|---|---|
| 7:0 | MIN | lowest |
| 15:8 | MAX | highest |

### CR_RANGE (0x54)

| Bits | Field | Description |
|---|---|---|
| 7:0 | MIN | lowest |
| 15:8 | MAX | highest |

### BLOB_CFG (0x5C)

| Bits | Field | Description |
|---|---|---|
| 7:0 | GAP | a run joins a blob within GAP columns of its box |
| 15:8 | GAP_Y | and at most GAP_Y + 1 lines below its last line |
| 31:16 | KEEP | fewest pixels of a blob kept (a closed smaller blob frees its slot; reported only from KEEP pixels) |

### RUN_B (0xD0)

| Bits | Field | Description |
|---|---|---|
| 11:0 | MIN_W | shortest run (0: 1) |
| 27:16 | MAX_W | longest run (0: no limit) |

### BLOB_X (0x100)

| Bits | Field | Description |
|---|---|---|
| 15:0 | X_MIN | min |
| 31:16 | X_MAX | max |

### BLOB_Y (0x120)

| Bits | Field | Description |
|---|---|---|
| 15:0 | Y_MIN | min |
| 31:16 | Y_MAX | max |
