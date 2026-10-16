<!-- Industry reference check of banked_framebuf: copied into docs/banked_framebuf_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - banked_framebuf (2026-10-16)
// Sources:
//   [1] D. G. Bailey, "Design for Embedded Image Processing on FPGAs", Wiley-IEEE Press 2011
//   (2nd ed. 2023), ISBN 978-0-470-82849-6,
//   https://www.oreilly.com/library/view/-/9780470828496/ - stream processing, line buffers and
//   window caching, border handling, memory partitioning / banking
// Published algorithm / equations:
//   Bailey 2011 (memory partitioning for window access): an image split over B x B banks with
//   bank = (y mod B, x mod B) and address = (y div B) * W/B + x div B lets any B x B window be
//   read in one clock, one access per bank.
// Comparison with this IP (section 6):
//   Matches: bank (y mod B, x mod B), address (y div B) * BW + x div B, B = next power of two
//   >= TAPS, clamp-to-edge windows stay conflict free, registered RAM reads.
// Result: in line with the reference; no TODO.
```
