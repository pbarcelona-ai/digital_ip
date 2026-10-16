<!-- Industry reference check of isp_csc: copied into docs/isp_csc_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_csc (2026-10-16)
// Sources:
//   [1] ITU-R BT.601-7 (2011) https://www.itu.int/rec/R-REC-BT.601 and BT.709-6 (2015)
//   https://www.itu.int/rec/R-REC-BT.709 - Kr/Kb 0.299/0.114 and 0.2126/0.0722, 8-bit Y = 16 +
//   219 E'Y, C = 128 + 224 E'C; scaled equations in Linux V4L2 colorspaces
//   https://docs.kernel.org/7.1/_sources/userspace-api/media/v4l/colorspaces-details.rst.txt
// Published algorithm / equations:
//   BT.601 / BT.709 limited range from full-range R'G'B' (0..255): Y = 16 + 219/255 (Kr R + Kg
//   G + Kb B), Cb = 128 + 224/255 * (B - Y') / (2 (1 - Kb)), Cr = 128 + 224/255 * (R - Y') / (2
//   (1 - Kr)); scaled by 256: BT.601 Y 65.74 129.06 25.07, Cb -37.95 -74.49 112.44, Cr 112.44
//   -94.15 -18.29; BT.709 Y 46.74 157.24 15.87, Cb -25.77 -86.67 112.44, Cr 112.44 -102.13
//   -10.31.
// Comparison with this IP (section 6):
//   BT.601 matches (66 129 25 / -38 -74 112 / 112 -94 -18, the classic integer set). BT.709 Y
//   and Cr match (47 157 16 / 112 -102 -10). Differs by one code: BT.709 Cb uses -86 for G
//   where the nearest integer is -87 (-86.67); -86 keeps the row sum 0 so grey maps to exactly
//   128, -87 is nearer the standard (both are within one LSB).
// TODO(REF-ISP_CSC-1) [LOW] BT.709 Cb G coefficient. Prompt: in
//   ip/video/isp_csc/src/isp_csc.sv, keep -86 and state in the header that it is chosen over
//   the nearest integer -87 so the Cb row sums to 0 (grey -> 128), or change it to -87 and the
//   Cb B coefficient to 113 (sum 0, nearest to 112.44 + the rounding), and update the testbench
//   reference model to the same integers; cite ITU-R BT.709-6 in the header.
```
