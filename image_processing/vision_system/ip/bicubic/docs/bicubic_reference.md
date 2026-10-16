<!-- Industry reference check of bicubic: copied into docs/bicubic_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - bicubic (2026-10-16)
// Sources:
//   [1] R. G. Keys, "Cubic convolution interpolation for digital image processing", IEEE Trans.
//   ASSP 29(6):1153-1160, 1981, doi:10.1109/TASSP.1981.1163711 (a = -0.5); E. Meijering, "A
//   chronology of interpolation", Proc. IEEE 2002,
//   https://bigwww.epfl.ch/publications/meijering0301.pdf
// Published algorithm / equations:
//   Keys cubic convolution with a = -0.5 (Catmull-Rom): w(t) = 1.5|t|^3 - 2.5|t|^2 + 1 for |t|
//   <= 1, -0.5|t|^3 + 2.5|t|^2 - 4|t| + 2 for 1 < |t| < 2; separable over a 4x4 footprint at
//   floor(x) + {-1, 0, 1, 2}; result clamped (the kernel overshoots).
// Comparison with this IP (section 6):
//   Matches: separable Catmull-Rom a = -0.5, 4x4 taps, clamped RGB888 output.
// Result: in line with the reference; no TODO.
```
