<!-- Industry reference check of isp_demosaic: copied into docs/isp_demosaic_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - isp_demosaic (2026-10-16)
// Sources:
//   [1] H. S. Malvar, L.-W. He, R. Cutler, "High-quality linear interpolation for demosaicing
//   of Bayer-patterned color images", ICASSP 2004 vol. 3 pp. iii-485,
//   https://www.cs.toronto.edu/~lindell/teaching/2529/reading/Demosaicing_ICASSP04.pdf
//   (bilinear baseline and the 5x5 gradient-corrected filters, +5.5 dB PSNR); review
//   https://www.ipol.im/pub/art/2011/g_mhcd/
//   [2] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
// Published algorithm / equations:
//   Bilinear demosaic (Malvar 2004, baseline): at R / B sites G = mean of the 4 cross
//   neighbours, the other colour = mean of the 4 diagonals; at G sites R / B = mean of the two
//   horizontal or vertical neighbours of that colour. Malvar-He-Cutler adds a Laplacian
//   correction from the centre colour with 5x5 filters (gains 1/2, 5/8, 3/4), +5.5 dB PSNR over
//   bilinear at similar cost.
// Comparison with this IP (section 6):
//   Matches the bilinear baseline exactly (3x3, rounded means, reflect-101 borders that keep
//   the CFA phase). Differs from the higher-quality industry practice: no gradient correction
//   (zipper and false colour at edges).
// TODO(REF-ISP_DEMOSAIC-1) [LOW] Optional Malvar-He-Cutler mode. Prompt: in
//   ip/video/isp_demosaic, add a parameter MHC (default 0) that switches to the 5x5 gradient-
//   corrected filters of Malvar, He, Cutler (ICASSP 2004, Fig. 2 coefficients, divide by 8,
//   round, clamp) using isp_window N = 5; keep bilinear as the default, document the latency
//   change, add a reference model and a PSNR comparison test on a synthetic image.
```
