<!-- Industry reference check of blur_sharpen: copied into docs/blur_sharpen_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - blur_sharpen (2026-10-16)
// Sources:
//   [1] R. C. Gonzalez, R. E. Woods, "Digital Image Processing", 4th ed., Pearson 2018, ch.
//   3.4-3.6 (spatial correlation / convolution, Gaussian / binomial smoothing, unsharp masking
//   and highboost g = f + k (f - f_blur), Sobel gradient |Gx| + |Gy|); unsharp summary
//   https://www.nv5geospatialsoftware.com/docs/UNSHARP_MASK.html
// Published algorithm / equations:
//   Smoothing with a binomial (Gaussian approximation) kernel; sharpening by unsharp masking g
//   = f + k (f - f_blur), which for a 3x3 kernel is the kernel (1 + k) delta - k * blur.
// Comparison with this IP (section 6):
//   Matches: programmable blur (reset binomial) and unsharp-mask sharpen kernels, frame-
//   consistent kernel changes, both orders.
// Result: in line with the reference; no TODO.
```
