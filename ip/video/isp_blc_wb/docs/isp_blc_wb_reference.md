<!-- Industry reference check of isp_blc_wb: copied into docs/isp_blc_wb_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_blc_wb (2026-10-16)
// Sources:
//   [1] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
//   [2] G. Buchsbaum, "A spatial processor model for object colour perception", J. Franklin
//   Institute 310(1), 1980 (grey-world: scene average is achromatic -> gains = mean(G) /
//   mean(c))
// Published algorithm / equations:
//   Ramanath 2005: black level is subtracted first (clip at 0), then white balance multiplies
//   each CFA colour by its gain (G = 1, R / B from the illuminant estimate, e.g. grey world).
//   Many ISPs also rescale after black-level subtraction so full scale stays full scale: v' =
//   (raw - blc) * Max / (Max - blc).
// Comparison with this IP (section 6):
//   Matches: per-CFA-colour black level with clip at 0, per-colour gains (Q4.8), saturation at
//   full scale, CFA phase from the pattern. The full-scale rescale is not a separate step; it
//   is obtained by folding Max / (Max - blc) into the gains (document that).
// RESOLVED(REF-ISP_BLC_WB-1) [LOW] Full-scale rescale after BLC. Resolution: 2026-10-21: the isp_blc_wb.sv header states that white tops out at 2^PW - 1 - blc[c] and how software scales
//   the gains (Ramanath 2005); video_processor's firmware leaves BLC at 0, so sw needs no change.
```
