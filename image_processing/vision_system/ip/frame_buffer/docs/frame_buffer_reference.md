<!-- Industry reference check of frame_buffer: copied into docs/frame_buffer_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - frame_buffer (2026-10-16)
// Sources:
//   [1] D. G. Bailey, "Design for Embedded Image Processing on FPGAs", Wiley-IEEE Press 2011
//   (2nd ed. 2023), ISBN 978-0-470-82849-6,
//   https://www.oreilly.com/library/view/-/9780470828496/ - stream processing, line buffers and
//   window caching, border handling, memory partitioning / banking
// Published algorithm / equations:
//   Parallel window access by memory partitioning (bank = (y mod 2, x mod 2) for 2x2, (y mod 2,
//   x mod 4) for 1x4 rows) instead of replication.
// Comparison with this IP (section 6):
//   Differs (code-review item already scheduled): the store is replicated four ways (4 x the
//   memory) instead of banked; the agreed fix is 8 banks (2 rows x 4 columns), bank (y % 2, x %
//   4), address (y >> 1) * (MAX_W / 4) + (x >> 2).
// TODO(REF-FRAME_BUFFER-1) [MEDIUM] Banked store. Prompt: in
//   image_processing/vision_system/ip/frame_buffer/src/frame_buffer.sv, replace the four
//   replicated copies with 8 banks of MAX_W*MAX_H/8 words, bank (y % 2, x % 4), address (y >>
//   1) * (MAX_W / 4) + (x >> 2), with x / y ports; a 2x2 bilinear read and a 1x4 bicubic row
//   read each touch distinct banks; update axis_in_ctrl / axis_out_ctrl to pass coordinates and
//   rerun the vision_system tests.
```
