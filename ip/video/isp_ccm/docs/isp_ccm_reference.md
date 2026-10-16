<!-- Industry reference check of isp_ccm: copied into docs/isp_ccm_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_ccm (2026-10-16)
// Sources:
//   [1] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
// Published algorithm / equations:
//   Colour correction: out = M * in (+ offset), M 3x3 with rows summing to 1 so white stays
//   white, applied on linear data after white balance and demosaic, before the tone curve.
// Comparison with this IP (section 6):
//   Matches: 3x3 signed Q5.10 matrix, offsets, rounding, clamping, identity = diag(1024),
//   placed after demosaic and before gamma in video_pipeline.
// Result: in line with the reference; no TODO.
```
