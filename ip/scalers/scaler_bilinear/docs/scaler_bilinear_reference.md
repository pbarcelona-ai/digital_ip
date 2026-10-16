<!-- Industry reference check of scaler_bilinear: copied into docs/scaler_bilinear_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - scaler_bilinear (2026-10-16)
// Sources:
//   [1] OpenCV, Geometric Image Transformations / cv::resize (INTER_LINEAR, half-pixel centres:
//   src = (dst + 0.5) * scale - 0.5, imgproc/src/resize.cpp),
//   https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html
//   [2] R. C. Gonzalez, R. E. Woods, "Digital Image Processing", 4th ed., Pearson 2018, ch.
//   3.4-3.6 (spatial correlation / convolution, Gaussian / binomial smoothing, unsharp masking
//   and highboost g = f + k (f - f_blur), Sobel gradient |Gx| + |Gy|); unsharp summary
//   https://www.nv5geospatialsoftware.com/docs/UNSHARP_MASK.html
// Published algorithm / equations:
//   Bilinear interpolation: f(x, y) = (1-fy)((1-fx) p00 + fx p01) + fy((1-fx) p10 + fx p11)
//   with fx, fy the fractional source position; OpenCV INTER_LINEAR maps destination pixel
//   centres to source centres, src = (dst + 0.5) * scale - 0.5, with replicated borders.
// Comparison with this IP (section 6):
//   Matches: separable bilinear weights with PHASE_BITS sub-pixel phases and round-to-nearest,
//   clamp-to-edge borders. The half-pixel alignment is programmed by software: OFFS = STEP / 2
//   - 0.5 (as the testbench's calc_offs does) reproduces OpenCV; the reset value OFFS = 0
//   aligns pixel corners instead.
// TODO(REF-SCALER_BILINEAR-1) [LOW] Document the centre alignment. Prompt: in
//   ip/scalers/scaler_ctrl/src/scaler_ctrl.sv and scaler_bilinear.sv headers, state that OFFS_X
//   / OFFS_Y = STEP / 2 - 0.5 (16.16: (STEP >> 1) - 0x8000) gives pixel-centre alignment as in
//   OpenCV cv::resize INTER_LINEAR, and make the firmware (sw/video_proc.py, scaler setup)
//   program that value.
```
