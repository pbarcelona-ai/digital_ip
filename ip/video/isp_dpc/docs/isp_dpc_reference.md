<!-- Industry reference check of isp_dpc: copied into docs/isp_dpc_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_dpc (2026-10-16)
// Sources:
//   [1] "Robust Defect Pixel Detection and Correction for Bayer Imaging Systems", IS&T
//   Electronic Imaging 2017, doi:10.2352/ISSN.2470-1173.2017.15.DPMI-088,
//   https://library.imaging.org/ei/articles/29/15/art00008; US 2005/0248671 "Single line Bayer
//   RGB bad pixel correction" (same-colour neighbours, threshold)
// Published algorithm / equations:
//   Dynamic defect pixel correction on Bayer data: compare each pixel with its same-colour
//   neighbours (two pixels apart); a pixel above the neighbours' maximum (hot) or below their
//   minimum (dead) by more than a threshold is replaced by an estimate from the neighbours
//   (clamp to max / min, median or mean).
// Comparison with this IP (section 6):
//   Matches: 8 same-colour neighbours at distance 2, threshold, clamp-to-max / clamp-to-min
//   replacement, reflect-101 borders keeping the colour phase, correction counter.
// Result: in line with the reference; no TODO.
```
