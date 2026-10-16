<!-- Industry reference check of scaler_dda: copied into docs/scaler_dda_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - scaler_dda (2026-10-16)
// Sources:
//   [1] OpenCV, Geometric Image Transformations / cv::resize (INTER_LINEAR, half-pixel centres:
//   src = (dst + 0.5) * scale - 0.5, imgproc/src/resize.cpp),
//   https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html
// Published algorithm / equations:
//   Inverse mapping for resampling: for each destination pixel compute its source coordinate
//   src = offset + dst * step (OpenCV: offset = 0.5 * step - 0.5 for centre alignment), usually
//   incrementally (digital differential analyser).
// Comparison with this IP (section 6):
//   Matches: src = OFFS + o * STEP by exact accumulation, signed 16.16, raster order, SOF / EOL
//   flags.
// Result: in line with the reference; no TODO.
```
