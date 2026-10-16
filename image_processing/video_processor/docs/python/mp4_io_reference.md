<!-- Industry reference check of mp4_io.py: copied into docs/python/mp4_io_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - mp4_io.py (2026-10-16)
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
//   [3] ITU-T H.264 / ISO/IEC 14496-10 (4:2:0 needs even frame sizes) in an ISO/IEC 14496-14
//   MP4 container, written through PyAV / libx264
// Published algorithm / rules:
//   GIF frames with per-frame median-cut palettes; H.264 4:2:0 MP4 with even sizes.
// Comparison with this program (section 6):
//   Matches: PIL median-cut quantisation, frame delays kept, even padding for 4:2:0, last frame
//   held.
// Result: in line with the reference; no TODO.
```
