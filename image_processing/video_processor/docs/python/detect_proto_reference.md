<!-- Industry reference check of detect_proto.py: copied into docs/python/detect_proto_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - detect_proto.py (2026-10-16)
// Sources:
//   [1] D. Chai, K. N. Ngan, "Face segmentation using skin-color map in videophone
//   applications", IEEE TCSVT 9(4):551-564, 1999, https://webarchive.lib.cuhk.edu.hk/2021032815
//   4327mp_/http:/www.ee.cuhk.edu.hk/~knngan/TCSVT_v9_n4_p551-564.pdf (skin map Cb 77-127, Cr
//   133-173 in BT.601 YCbCr)
//   [2] ITU-R BT.601-7 (2011) https://www.itu.int/rec/R-REC-BT.601 and BT.709-6 (2015)
//   https://www.itu.int/rec/R-REC-BT.709 - Kr/Kb 0.299/0.114 and 0.2126/0.0722, 8-bit Y = 16 +
//   219 E'Y, C = 128 + 224 E'C; scaled equations in Linux V4L2 colorspaces
//   https://docs.kernel.org/7.1/_sources/userspace-api/media/v4l/colorspaces-details.rst.txt
//   [3] I. Haritaoglu, D. Harwood, L. S. Davis, "W4: Real-time surveillance of people and their
//   activities", IEEE PAMI 22(8), 2000, doi:10.1109/34.868683 (background as per-pixel minimum
//   / maximum intensity, foreground outside it)
//   [4] D. G. Bailey, C. T. Johnston, "Single pass connected components analysis", IVCNZ 2007;
//   N. Ma, D. G. Bailey, C. T. Johnston, "Optimised single pass connected components analysis",
//   FPT 2008, https://sfat.massey.ac.nz/research/centres/crisp/pdfs/2008_FPT_185.pdf; MathWorks
//   Vision HDL blob analysis https://www.mathworks.com/help/visionhdl/ug/blob-analysis.html
//   [5] P. R. Kalata, "The Tracking Index: A Generalized Parameter for alpha-beta and alpha-
//   beta-gamma Target Trackers", IEEE Trans. AES 20(2):174-182, 1984; summary
//   https://en.wikipedia.org/wiki/Alpha_beta_filter (x_p = x + v T; r = z - x_p; x += alpha r;
//   v += beta r / T)
// Published algorithm / rules:
//   Prototype of the hardware detectors and firmware tracking. Skin colour: Chai & Ngan Cb
//   77-127, Cr 133-173 in BT.601 YCbCr (Cb = 128 + 0.564 (B - Y), Y = 0.299 R + 0.587 G + 0.114
//   B).
// Comparison with this program (section 6):
//   Mirrors the hardware exactly (luma (R + 2G + B) / 4, chroma (B - Y) / 2, run / blob
//   grouping, W4-style motion), as a model must. Differs from the reference: the skin window
//   (Cb 77-127, Cr 135-175) is Chai & Ngan's BT.601 window applied to the approximate chroma,
//   whose scale is 0.5 instead of 0.564 / 0.713, so the window is shifted relative to the
//   published one (the learned skin table compensates when used).
// RESOLVED(REF-DETECT_PROTO-1) [LOW] Skin window in the approximate colour space. Resolution:
//   2026-10-16: the fixed rule is documented as Chai & Ngan's window in the approximate chroma;
//   the learned table (SKIN_LUT) stays the default.
```
