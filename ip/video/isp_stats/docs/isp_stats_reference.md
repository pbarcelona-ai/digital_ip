<!-- Industry reference check of isp_stats: copied into docs/isp_stats_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_stats (2026-10-16)
// Sources:
//   [1] G. Buchsbaum, "A spatial processor model for object colour perception", J. Franklin
//   Institute 310(1), 1980 (grey-world: scene average is achromatic -> gains = mean(G) /
//   mean(c))
//   [2] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
// Published algorithm / equations:
//   Grey-world AWB needs the per-channel means (sums / pixel count); AE needs the mean luma and
//   the number of clipped pixels.
// Comparison with this IP (section 6):
//   Matches: per-component sums, pixel count, clipped-pixel count per frame, latched at the
//   next SOF.
// Result: in line with the reference; no TODO.
```
