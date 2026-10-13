# vision_system register map

Lens distortion correction: control, status, image size, distortion coefficients, calibration, model select, homography.

| Offset | Name | Access | Reset | Description |
|---|---|---|---|---|
| 0x00 | ID | RO | "VSYS" | IP identifier, 4 ASCII characters (first in [31:24]) |
| 0x04 | VERSION | RO | - | version, ASCII "d.dd" (+0.01 at every source update) |
| 0x08 | DATE | RO | - | date of the last source update, BCD mm/dd/yyyy (0xMMDDYYYY) |
| 0x0C | reserved | RO | 0 | |
| 0x10 | CTRL | WO | 0x00000000 | [0] soft reset request (self clearing, not stored) |
| 0x14 | STATUS | CMD | 0x00000000 | [0] busy [1] frame done (W1C) [2] reciprocal busy |
| 0x18 | IMG_WIDTH | RW | 0x00000040 | active frame width, 1..MAX_W |
| 0x1C | IMG_HEIGHT | RW | 0x00000040 | active frame height, 1..MAX_H |
| 0x20 | K1 | RW | 0x00000000 | signed Q16.16 radial coefficient (r^2 term) |
| 0x24 | K2 | RW | 0x00000000 | signed Q16.16 radial coefficient (r^4 term) |
| 0x28 | K3 | RW | 0x00000000 | signed Q16.16 radial coefficient (r^6 term) |
| 0x2C | CENTER_X | RW | 0x00008000 | unsigned Q16.16, fraction of the width (0.5 = 0x8000) |
| 0x30 | CENTER_Y | RW | 0x00008000 | unsigned Q16.16, fraction of the height |
| 0x34 | SCALE | RW | 0x00010000 | unsigned Q16.16 edge-crop zoom (1.0 = 0x10000) |
| 0x3C | INTERP_MODE | RW | 0x00000000 | [0] 0 bilinear, 1 bicubic (change only while idle) |
| 0x40 | CALIB_MODE | RW | 0x00000000 | [0] 1 = direct camera calibration (FX / FY / CX / CY) |
| 0x44 | FX | RW | 0x00010000 | signed Q16.16 pixels, focal length x (CALIB_MODE 1) |
| 0x48 | FY | RW | 0x00010000 | signed Q16.16 pixels, focal length y (CALIB_MODE 1) |
| 0x4C | CX | RW | 0x00000000 | signed Q16.16 pixels, principal point x (CALIB_MODE 1) |
| 0x50 | CY | RW | 0x00000000 | signed Q16.16 pixels, principal point y (CALIB_MODE 1) |
| 0x54 | P1 | RW | 0x00000000 | signed Q16.16 tangential coefficient 1 (RADIAL) |
| 0x58 | P2 | RW | 0x00000000 | signed Q16.16 tangential coefficient 2 (RADIAL) |
| 0x5C | MODEL_SEL | RW | 0x00000000 | [2:0] 0 radial, 1 fisheye, 2 affine (reserved), 3 perspective, 4 scaling (reserved), 5 panoramic |
| 0x60 | H11 | RW | 0x00010000 | homography, Q16.16 |
| 0x64 | H12 | RW | 0x00000000 | homography, Q16.16 |
| 0x68 | H13 | RW | 0x00000000 | homography translation, pixels |
| 0x6C | H21 | RW | 0x00000000 | homography, Q16.16 |
| 0x70 | H22 | RW | 0x00010000 | homography, Q16.16 |
| 0x74 | H23 | RW | 0x00000000 | homography translation, pixels |
| 0x78 | H31 | RW | 0x00000000 | homography, Q16.16 |
| 0x7C | H32 | RW | 0x00000000 | homography, Q16.16 |
