# feature_detect register map

Edge and motion features of a video stream for object detectors: Sobel edges and a background of cells (lowest / highest luma) with the camera shift from luma profiles, two bits per pixel.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "FEAT" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x18 | CTRL | RW | 0x00000000 | control |
| 0x1C | FRAME_SIZE | RW | 0x00000000 | frame size |
| 0x20 | EDGE | RW | 0x00080080 | edge detector |
| 0x24 | MOTION | RW | 0x00002214 | motion detector |
| 0x28 | SHIFT | RW | 0x00000000 | camera shift used without AUTO_SHIFT (cells, taken at the frame start) |
| 0x2C | SHIFT_EST | RO | 0x00000000 | camera shift found by the last search (cells) |
| 0x30 | STATUS | RO | 0x00000000 | state |
| 0x34 | FRAMES | RO | 0x00000000 | frames seen |
| 0x38 | EDGE_COUNT | RO | 0x00000000 | pixels with the edge bit in the last frame |
| 0x3C | MOTION_COUNT | RO | 0x00000000 | pixels with the motion bit in the last frame |
| 0x40 | SHIFT_USED | RO | 0x00000000 | camera shift in effect for the current / last frame (cells) |

### CTRL (0x18)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | enable (follow the stream) |
| 1 | EDGE_EN | edge bit on |
| 2 | MOTION_EN | motion bit on |
| 3 | AUTO_SHIFT | use the searched camera shift (else SHIFT) |
| 4 | RESTART | write 1: background, profiles and shift start again (the next frame fills the background) |

### FRAME_SIZE (0x1C)

| Bits | Field | Description |
|---|---|---|
| 15:0 | WIDTH | width |
| 31:16 | HEIGHT | height |

### EDGE (0x20)

| Bits | Field | Description |
|---|---|---|
| 10:0 | THRESH | Sobel |Gx| + |Gy| above this: an edge |
| 19:16 | SPAN | an edge in the last SPAN pixels of the line sets the bit (0 or 1: the pixel only) |

### MOTION (0x24)

| Bits | Field | Description |
|---|---|---|
| 7:0 | THRESH | luma beyond the background cell's range by more than this: moving |
| 11:8 | SPAN | fill along the line, as EDGE.SPAN |
| 14:12 | RATE | background moves 1 / 2^RATE of the way to each frame |

### SHIFT (0x28)

| Bits | Field | Description |
|---|---|---|
| 7:0 | X | columns (signed): content moved right |
| 15:8 | Y | lines (signed): content moved down |

### SHIFT_EST (0x2C)

| Bits | Field | Description |
|---|---|---|
| 7:0 | X | columns (signed) |
| 15:8 | Y | lines (signed) |

### STATUS (0x30)

| Bits | Field | Description |
|---|---|---|
| 0 | IN_FRAME | in a frame |
| 1 | BG_VALID | background valid (motion detected) |
| 2 | BUSY | shift search running |
| 31:16 | FRAMES | FRAMES[15:0] |

### SHIFT_USED (0x40)

| Bits | Field | Description |
|---|---|---|
| 7:0 | X | columns (signed) |
| 15:8 | Y | lines (signed) |
