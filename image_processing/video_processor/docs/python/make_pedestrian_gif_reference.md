<!-- Industry reference check of make_pedestrian_gif.py: copied into docs/python/make_pedestrian_gif_prompt.md section 6a by ip/scripts/make_py_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - make_pedestrian_gif.py (2026-10-16)
// Sources:
//   [1] CompuServe, "Graphics Interchange Format Version 89a" (1990),
//   https://www.nayuki.io/page/gif89a-specification-html (LZW minimum code size, clear = 2^min,
//   EOI = clear + 1, code width grows when the next code reaches 2^width, 12-bit maximum,
//   255-byte sub-blocks, graphic control extension); LZW walkthrough
//   https://giflib.sourceforge.net/whatsinagif/lzw_image_data.html; NETSCAPE2.0 loop extension
//   (de facto)
//   [2] K. Perlin, "An image synthesizer", SIGGRAPH 1985; F. K. Musgrave in Ebert et al.,
//   "Texturing and Modeling: A Procedural Approach" (fBm = sum of octaves, frequency x
//   lacunarity, amplitude x gain); https://thebookofshaders.com/13/
// Published algorithm / rules:
//   GIF89a: header, logical screen with global colour table, LZW image data (minimum code size
//   8 for 256 colours, clear / EOI codes, width growth, 12-bit limit, clear when full),
//   255-byte sub-blocks, graphic control extension per frame, trailer 0x3B. Textures: value
//   noise summed over octaves (fBm).
// Comparison with this program (section 6):
//   Matches: LZW codes and width growth as in the spec, clear when the table is full, sub-
//   blocks, GCE with disposal 1, NETSCAPE2.0 looping (a de facto extension, not part of
//   GIF89a), fBm textures.
// Result: in line with the reference; no TODO.
```
