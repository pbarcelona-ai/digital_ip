# blur_sharpen register map

Blur / sharpen filter pair: mode, frame size, shifts and both kernel banks (taken at a frame start by the filter).

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "BLSH" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x14 | MODE | RW | 0x00000000 | 0 blur, 1 sharpen, 2 sharpen then blur, 3 blur then sharpen, 4-7 pass-through |
| 0x18 | FRAME_SIZE | RW | `{RESET_H, RESET_W}` | [15:0] width [31:16] height (>= (N+1)/2 each) |
| 0x1C | BLUR_SHIFT | RW | `conv2d_pkg::blur_shift(N)` | blur normalisation shift |
| 0x20 | SHARP_SHIFT | RW | `conv2d_pkg::blur_shift(N)` | sharpen normalisation shift |
| 0x24 | STATUS | RO | 0x00000000 | [2:0] mode of the last frame that entered [31:16] frames out |
| 0x28 | INFO | RO | 0x00000000 | [3:0] N [11:8] COEF_W [23:16] C [31:24] CW |
| 0x50 + 4 i (i < N * N) | BLUR_K | RW | `K_BLUR[i*32 +: 32]` | blur kernel coefficient i = r*N + c, signed |
| 0xD0 + 4 i (i < N * N) | SHARP_K | RW | `K_SHARP[i*32 +: 32]` | sharpen kernel coefficient i, signed |
