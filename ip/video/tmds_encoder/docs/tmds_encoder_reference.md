<!-- Industry reference check of tmds_encoder: copied into docs/tmds_encoder_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - tmds_encoder (2026-10-16)
// Sources:
//   [1] Digital Display Working Group, "Digital Visual Interface DVI" Rev. 1.0 (1999),
//   https://www.ttiinc.com/content/dam/ttiinc/manufacturers/molex/doc/molex-digital-display-
//   working-group-dvi-specification.pdf - 3.2.2 TMDS encoding algorithm (Figure 3-5), control
//   tokens, cnt reset in blanking, q_out[0] sent first
//   [2] HDMI Licensing, "High-Definition Multimedia Interface Specification" 1.4b (2011)
//   5.2-5.4 (preambles, guard bands, TERC4, data island, BCH ECC) and CTA-861-G 6.4 (AVI
//   InfoFrame, checksum: all bytes sum to 0); overview https://www.prodigytechno.com/wp-
//   content/uploads/2020/01/TEK-PGY-HDMI_MHL_Application_Notes_V1.0.pdf
// Published algorithm / equations:
//   DVI 1.0 Figure 3-5: stage 1 chooses XOR or XNOR (XNOR when N1(D) > 4 or N1(D) == 4 and D[0]
//   == 0) to minimise transitions, q_m[8] = 1 for XOR; stage 2 inverts q_m[7:0] when that
//   reduces the running disparity (cnt), q_out[9] marks the inversion; cnt is reset to 0 while
//   DE is low; control tokens 1101010100 / 0010101011 / 0101010100 / 1010101011 for C1C0 = 00 /
//   01 / 10 / 11. HDMI adds TERC4 (16 10-bit symbols) and the guard-band symbols.
// Comparison with this IP (section 6):
//   Matches: the two-stage DVI algorithm with running disparity, the four control tokens,
//   TERC4, guard bands, cnt cleared outside video, q_o[0] first on the wire.
// Result: in line with the reference; no TODO.
```
