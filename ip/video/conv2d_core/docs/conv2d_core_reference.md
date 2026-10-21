<!-- Industry reference check of conv2d_core: copied into docs/conv2d_core_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - conv2d_core (2026-10-16)
// Sources:
//   [1] R. C. Gonzalez, R. E. Woods, "Digital Image Processing", 4th ed., Pearson 2018, ch.
//   3.4-3.6 (spatial correlation / convolution, Gaussian / binomial smoothing, unsharp masking
//   and highboost g = f + k (f - f_blur), Sobel gradient |Gx| + |Gy|); unsharp summary
//   https://www.nv5geospatialsoftware.com/docs/UNSHARP_MASK.html
//   [2] D. G. Bailey, "Design for Embedded Image Processing on FPGAs", Wiley-IEEE Press 2011
//   (2nd ed. 2023), ISBN 978-0-470-82849-6,
//   https://www.oreilly.com/library/view/-/9780470828496/ - stream processing, line buffers and
//   window caching, border handling, memory partitioning / banking
// Published algorithm / equations:
//   2-D convolution g(x, y) = sum_s sum_t w(s, t) f(x + s, y + t) (Gonzalez & Woods 3.4; with
//   the kernel not rotated this is correlation, identical for symmetric kernels), normalised by
//   a power of two, rounded and clamped for integer images.
// Comparison with this IP (section 6):
//   Matches: N x N signed kernel, round-half-up shift, clamp, borders from isp_window. Note:
//   the sum is correlation (k[r*N+c] multiplies the pixel at row r, column c); for non-
//   symmetric kernels the kernel must be given rotated by 180 degrees to obtain mathematical
//   convolution (document).
// RESOLVED(REF-CONV2D_CORE-1) [LOW] Correlation vs convolution. Resolution: 2026-10-21: the
//   conv2d_core.sv header states that the block computes correlation (k[r*N + c] weights window
//   row r, column c) and that a convolution kernel is loaded rotated by 180 degrees; the golden
//   model (model/conv2d_core_model.py) defines the same sum and tb/python checks it beat for beat.
```
