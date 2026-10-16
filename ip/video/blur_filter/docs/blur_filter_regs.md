# blur_filter register map

Blurring filter: binomial (Gaussian) reset kernel. The settings are copied at each frame start.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "BLRF" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x14 | FRAME_SIZE | RW | `{RESET_H, RESET_W}` | [15:0] width [31:16] height (>= (N+1)/2 each) |
| 0x18 | SHIFT | RW | `SHIFT` | result right shift (normalisation) |
| 0x1C | STATUS | RO | 0x00000000 | [15:0] frames filtered |
| 0x20 | INFO | RO | 0x00000000 | [3:0] N [11:8] COEF_W [23:16] C [31:24] CW |
| 0x50 + 4 i (i < N * N) | K | RW | `KERNEL[i*32 +: 32]` | signed coefficient i = r*N + c |
