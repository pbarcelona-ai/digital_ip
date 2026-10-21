<!-- Industry reference check of feature_detect: copied into docs/feature_detect_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - feature_detect (2026-10-16)
// Sources:
//   [1] R. C. Gonzalez, R. E. Woods, "Digital Image Processing", 4th ed., Pearson 2018, ch.
//   3.4-3.6 (spatial correlation / convolution, Gaussian / binomial smoothing, unsharp masking
//   and highboost g = f + k (f - f_blur), Sobel gradient |Gx| + |Gy|); unsharp summary
//   https://www.nv5geospatialsoftware.com/docs/UNSHARP_MASK.html
//   [2] I. Haritaoglu, D. Harwood, L. S. Davis, "W4: Real-time surveillance of people and their
//   activities", IEEE PAMI 22(8), 2000, doi:10.1109/34.868683 (background as per-pixel minimum
//   / maximum intensity, foreground outside it)
//   [3] K. Ratakonda, "Real-time digital video stabilization for multi-media applications",
//   ISCAS 1998 vol. 4 pp. 69-72 (row / column integral projections, 1-D shift search by minimum
//   SAD)
//   [4] ITU-R BT.601-7 (2011) https://www.itu.int/rec/R-REC-BT.601 and BT.709-6 (2015)
//   https://www.itu.int/rec/R-REC-BT.709 - Kr/Kb 0.299/0.114 and 0.2126/0.0722, 8-bit Y = 16 +
//   219 E'Y, C = 128 + 224 E'C; scaled equations in Linux V4L2 colorspaces
//   https://docs.kernel.org/7.1/_sources/userspace-api/media/v4l/colorspaces-details.rst.txt
// Published algorithm / equations:
//   Edges: Sobel gradient with |Gx| + |Gy| as the magnitude approximation (Gonzalez & Woods
//   10.2). Motion: W4 background = per-pixel (here per-cell) minimum / maximum intensity, a
//   pixel is foreground outside [min - t, max + t]. Global (camera) shift: integral projections
//   of rows and columns matched by minimum SAD (Ratakonda 1998). Luma: BT.601 Y = 0.299 R +
//   0.587 G + 0.114 B.
// Comparison with this IP (section 6):
//   Matches: 3x3 Sobel with L1 magnitude, W4-style min / max background with threshold and slow
//   update, projection-profile shift search by minimum SAD. Differs: luma is (R + 2G + B) / 4 =
//   0.25 R + 0.5 G + 0.25 B, not BT.601 (blue weighted 0.25 instead of 0.114), so blue objects
//   look brighter to the edge and motion tests than in a standard luma image.
// RESOLVED(REF-FEATURE_DETECT-1) [LOW] Luma weights. Resolution: 2026-10-21: Y = (R + 2G + B) / 4
//   is kept (shift-add, no multipliers); the feature_detect.sv header states that it approximates
//   BT.601 luma (ITU-R BT.601-7) and that blue weighs 0.25 instead of 0.114; the golden model uses
//   the same luma (pixel.luma) and tb/python checks every pixel.
```
