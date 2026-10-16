<!-- Industry reference check of isp_gamma: copied into docs/isp_gamma_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_gamma (2026-10-16)
// Sources:
//   [1] IEC 61966-2-1:1999 sRGB transfer function (V = 12.92 L for L <= 0.0031308, else 1.055
//   L^(1/2.4) - 0.055), ICC registry https://registry.color.org/rgb-registry/srgb
//   [2] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
// Published algorithm / equations:
//   Tone / gamma curve as a lookup table on each component; the usual display encoding is sRGB
//   (linear segment 12.92 L below 0.0031308, else 1.055 L^(1/2.4) - 0.055) or BT.709 OETF.
// Comparison with this IP (section 6):
//   Matches: programmable 2^IN_W-entry LUT per component, so any curve (sRGB, BT.709, custom)
//   can be loaded; the power-up curve is linear, so software must load the encoding curve.
// Result: in line with the reference; no TODO.
```
