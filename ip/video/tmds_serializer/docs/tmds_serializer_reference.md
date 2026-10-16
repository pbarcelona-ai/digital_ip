<!-- Industry reference check of tmds_serializer: copied into docs/tmds_serializer_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - tmds_serializer (2026-10-16)
// Sources:
//   [1] Digital Display Working Group, "Digital Visual Interface DVI" Rev. 1.0 (1999),
//   https://www.ttiinc.com/content/dam/ttiinc/manufacturers/molex/doc/molex-digital-display-
//   working-group-dvi-specification.pdf - 3.2.2 TMDS encoding algorithm (Figure 3-5), control
//   tokens, cnt reset in blanking, q_out[0] sent first
// Published algorithm / equations:
//   DVI: each 10-bit TMDS character is sent LSB (q_out[0]) first at 10x the pixel clock; the
//   clock channel carries the pixel clock (pattern 1111100000).
// Comparison with this IP (section 6):
//   Matches: LSB first, ser_clk = 10 x pix_clk from the same PLL, clock pattern lane.
// Result: in line with the reference; no TODO.
```
