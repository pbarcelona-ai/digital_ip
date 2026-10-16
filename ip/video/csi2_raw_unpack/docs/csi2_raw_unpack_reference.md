<!-- Industry reference check of csi2_raw_unpack: copied into docs/csi2_raw_unpack_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - csi2_raw_unpack (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [2] Linux V4L2, "10-bit packed Bayer formats" (CSI-2 RAW10: four MSB bytes then one byte of
//   2-bit LSBs, pixel 0 in bits [1:0]), https://docs.kernel.org/5.3/media/uapi/v4l/pixfmt-
//   srggb10p.html
// Published algorithm / equations:
//   CSI-2 RAW8 (0x2A) one byte per pixel; RAW10 (0x2B) 4 pixels in 5 bytes, bytes 0-3 = bits
//   [9:2], byte 4 = bits [1:0] of pixels 0..3 in bits [1:0], [3:2], [5:4], [7:6]; RAW12 (0x2C)
//   2 pixels in 3 bytes, byte 2 = pixel 0 bits [3:0] in [3:0], pixel 1 in [7:4].
// Comparison with this IP (section 6):
//   Matches both packings exactly; line lengths in whole groups as CSI-2 requires.
// Result: in line with the reference; no TODO.
```
