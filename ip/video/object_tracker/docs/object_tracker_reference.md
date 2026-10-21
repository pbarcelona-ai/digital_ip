<!-- Industry reference check of object_tracker: copied into docs/object_tracker_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - object_tracker (2026-10-16)
// Sources:
//   [1] D. G. Bailey, C. T. Johnston, "Single pass connected components analysis", IVCNZ 2007;
//   N. Ma, D. G. Bailey, C. T. Johnston, "Optimised single pass connected components analysis",
//   FPT 2008, https://sfat.massey.ac.nz/research/centres/crisp/pdfs/2008_FPT_185.pdf; MathWorks
//   Vision HDL blob analysis https://www.mathworks.com/help/visionhdl/ug/blob-analysis.html
//   [2] ITU-R BT.601-7 (2011) https://www.itu.int/rec/R-REC-BT.601 and BT.709-6 (2015)
//   https://www.itu.int/rec/R-REC-BT.709 - Kr/Kb 0.299/0.114 and 0.2126/0.0722, 8-bit Y = 16 +
//   219 E'Y, C = 128 + 224 E'C; scaled equations in Linux V4L2 colorspaces
//   https://docs.kernel.org/7.1/_sources/userspace-api/media/v4l/colorspaces-details.rst.txt
// Published algorithm / equations:
//   Streaming blob analysis: single-pass connected-components labelling of runs, merging labels
//   when a run touches several, per-blob bounding box / area / centroid sums, no frame store
//   (Bailey & Johnston). Colour tests in YCbCr per BT.601: Cb = 128 + 0.564 (B - Y), Cr = 128 +
//   0.713 (R - Y).
// Comparison with this IP (section 6):
//   Matches: run-length based single-pass grouping with merges, boxes, counts and sums, slot
//   reuse. Differs: grouping uses box proximity (GAP / GAP_Y) rather than strict 8-connectivity
//   (intentional, joins parts split by windows); luma (R + 2G + B) / 4 and chroma (B - Y) / 2,
//   (R - Y) / 2 approximate BT.601 (0.564 and 0.713 scale factors), so skin-tone / colour
//   ranges tuned on standard YCbCr do not carry over directly.
// RESOLVED(REF-OBJECT_TRACKER-1) [LOW] Colour space approximation. Resolution: 2026-10-21: the
//   object_tracker.sv header states that Y / Cb / Cr are the shift-add approximations (not BT.601,
//   ITU-R BT.601-7 quoted), how a BT.601 range converts (Cb = 128 + 0.89 (Cb601 - 128), Cr = 128 +
//   0.70 (Cr601 - 128)), that SKIN_LUT is learned in this space, and that blobs are grouped by box
//   proximity, not pixel connectivity.
```
