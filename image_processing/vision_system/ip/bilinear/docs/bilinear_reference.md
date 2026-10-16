<!-- Industry reference check of bilinear: copied into docs/bilinear_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - bilinear (2026-10-16)
// Sources:
//   [1] OpenCV, Geometric Image Transformations / cv::resize (INTER_LINEAR, half-pixel centres:
//   src = (dst + 0.5) * scale - 0.5, imgproc/src/resize.cpp),
//   https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html
// Published algorithm / equations:
//   Bilinear: (1-fy)((1-fx) p00 + fx p01) + fy((1-fx) p10 + fx p11).
// Comparison with this IP (section 6):
//   Matches: 8-bit fractional weights, 2x2 taps, one pixel per clock.
// Result: in line with the reference; no TODO.
```
