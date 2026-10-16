<!-- Industry reference check of eval_faces.py: copied into docs/python/eval_faces_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - eval_faces.py (2026-10-16)
// Sources:
//   [1] D. Chai, K. N. Ngan, "Face segmentation using skin-color map in videophone
//   applications", IEEE TCSVT 9(4):551-564, 1999, https://webarchive.lib.cuhk.edu.hk/2021032815
//   4327mp_/http:/www.ee.cuhk.edu.hk/~knngan/TCSVT_v9_n4_p551-564.pdf (skin map Cb 77-127, Cr
//   133-173 in BT.601 YCbCr)
// Published algorithm / rules:
//   Detection evaluation: count true / false detections against labelled boxes.
// Comparison with this program (section 6):
//   Matches: per-frame box comparison against labels. No difference.
// Result: in line with the reference; no TODO.
```
