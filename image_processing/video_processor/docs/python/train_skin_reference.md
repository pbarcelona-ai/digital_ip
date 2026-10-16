<!-- Industry reference check of train_skin.py: copied into docs/python/train_skin_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - train_skin.py (2026-10-16)
// Sources:
//   [1] D. Chai, K. N. Ngan, "Face segmentation using skin-color map in videophone
//   applications", IEEE TCSVT 9(4):551-564, 1999, https://webarchive.lib.cuhk.edu.hk/2021032815
//   4327mp_/http:/www.ee.cuhk.edu.hk/~knngan/TCSVT_v9_n4_p551-564.pdf (skin map Cb 77-127, Cr
//   133-173 in BT.601 YCbCr)
// Published algorithm / rules:
//   Learn a Cb / Cr skin table from labelled frames (histogram / table method).
// Comparison with this program (section 6):
//   Matches the table approach; the fixed_rule baseline uses the shifted window noted in
//   detect_proto.
// Result: in line with the reference; no TODO.
```
