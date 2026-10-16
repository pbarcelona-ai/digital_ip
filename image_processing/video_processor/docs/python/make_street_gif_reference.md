<!-- Industry reference check of make_street_gif.py: copied into docs/python/make_street_gif_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - make_street_gif.py (2026-10-16)
// Sources:
//   [1] CompuServe, "Graphics Interchange Format Version 89a" (1990),
//   https://www.nayuki.io/page/gif89a-specification-html (LZW minimum code size, clear = 2^min,
//   EOI = clear + 1, code width grows when the next code reaches 2^width, 12-bit maximum,
//   255-byte sub-blocks, graphic control extension); LZW walkthrough
//   https://giflib.sourceforge.net/whatsinagif/lzw_image_data.html; NETSCAPE2.0 loop extension
//   (de facto)
//   [2] P. Heckbert, "Color image quantization for frame buffer display", SIGGRAPH 1982 pp.
//   297-307 (median cut: split the box with the largest range at the median of its longest
//   axis)
// Published algorithm / rules:
//   GIF89a as above; palette by median cut (Heckbert 1982).
// Comparison with this program (section 6):
//   Matches: median cut splitting the box with the largest range at the median of its widest
//   channel; GIF writer shared with make_pedestrian_gif.
// Result: in line with the reference; no TODO.
```
