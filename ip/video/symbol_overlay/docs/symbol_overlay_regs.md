# symbol_overlay register map

Symbols (boxes, circles, crosshairs) and texts drawn over a video stream; every change applies at the next frame start after COMMIT.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "SOVL" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x18 | CTRL | RW | 0x00000000 | [0] enable (taken at a frame start) |
| 0x1C | COMMIT | CMD | 0x00000000 | write 1: the object and text registers apply at the next frame start; reads [0] commit pending |
| 0x20 | STATUS | RO | 0x00000000 | state |
| 0x24 | FRAME_NUM | CMD | 0x00000000 | write: the number (5 BCD digits) the next frame shows, then one more per frame; read: the last frame's |
| 0x50 + 16 i (i < NOBJ) | OBJ_CTRL | RW | 0x00000000 | object i |
| 0x54 + 16 i (i < NOBJ) | OBJ_X | RW | 0x00000000 | object i columns: [15:0] x0 [31:16] x1 |
| 0x58 + 16 i (i < NOBJ) | OBJ_Y | RW | 0x00000000 | object i lines: [15:0] y0 [31:16] y1 |
| 0x5C + 16 i (i < NOBJ) | OBJ_COLOR | RW | 0x00000000 | object i colour, pixel as on the stream ([7:0] R [15:8] G [23:16] B) |
| 0x110 + 16 i (i < (NTXT < 1 ? 1 : NTXT)) | TXT_CTRL | RW | 0x00000000 | text j |
| 0x114 + 16 i (i < (NTXT < 1 ? 1 : NTXT)) | TXT_POS | RW | 0x00000000 | text j top-left corner: [15:0] x [31:16] y |
| 0x118 + 16 i (i < (NTXT < 1 ? 1 : NTXT)) | TXT_COLOR | RW | 0x00000000 | text j colour, pixel as on the stream |
| 0x210 + 4 i (i < 4 * (NTXT < 1 ? 1 : NTXT)) | TXT_CHARS | RW | 0x00000000 | characters: word 4 j + q of text j holds characters 4 q .. 4 q + 3 (ASCII, character 4 q in [7:0]) |

### STATUS (0x20)

| Bits | Field | Description |
|---|---|---|
| 0 | PENDING | commit pending |
| 31:16 | FRAMES | frames (low 16 bits) |

### OBJ_CTRL (0x50)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | enable |
| 2:1 | SHAPE | 0 rectangle outline, 1 filled, 2 crosshair, 3 circle (radius = half the larger side) |
| 3 | DASHED | dashed |
| 4 | BLEND | 50 % blend |
| 5 | OVAL | shape 3: an oval (ellipse) inside the box instead of the circle |
| 11:8 | LINE_W | line width (0 = 1) |
| 14:12 | DASH_LOG2 | dash length log2 |

### TXT_CTRL (0x110)

| Bits | Field | Description |
|---|---|---|
| 0 | EN | enable |
| 2:1 | SCALE | scale log2 (0-2: 1x, 2x, 4x) |
| 3 | BACKDROP | darken the video under the text |
| 4 | FNUM | the frame number after the characters |
| 12:8 | LENGTH | characters (0-16) |
