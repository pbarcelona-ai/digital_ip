<!-- Industry reference check of hdmi_tx: copied into docs/hdmi_tx_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - hdmi_tx (2026-10-16)
// Sources:
//   [1] HDMI Licensing, "High-Definition Multimedia Interface Specification" 1.4b (2011)
//   5.2-5.4 (preambles, guard bands, TERC4, data island, BCH ECC) and CTA-861-G 6.4 (AVI
//   InfoFrame, checksum: all bytes sum to 0); overview https://www.prodigytechno.com/wp-
//   content/uploads/2020/01/TEK-PGY-HDMI_MHL_Application_Notes_V1.0.pdf
//   [2] Digital Display Working Group, "Digital Visual Interface DVI" Rev. 1.0 (1999),
//   https://www.ttiinc.com/content/dam/ttiinc/manufacturers/molex/doc/molex-digital-display-
//   working-group-dvi-specification.pdf - 3.2.2 TMDS encoding algorithm (Figure 3-5), control
//   tokens, cnt reset in blanking, q_out[0] sent first
//   [3] CTA-861-H, "A DTV Profile for Uncompressed High Speed Digital Interfaces" (2021),
//   section 4 video formats and waveform timings (e.g. VIC 4 1280x720p60: H 1280/110/40/220, V
//   720/5/5/20, +/+ sync); VIC table in libdisplay-info
//   https://gitlab.freedesktop.org/emersion/libdisplay-info
// Published algorithm / equations:
//   HDMI 1.4b 5.2: control period, 8-clock preamble (CTL0..3 = 1000 before video, 1010 before a
//   data island), 2-clock leading guard band; video guard band 1011001100 / 0100110011 /
//   1011001100 on channels 0 / 1 / 2; data island = 32-clock packets with TERC4 coding, guard
//   bands before and after, channel 0 carrying {bit3: not first, bit2: header bit, VS, HS};
//   packet header and 4 sub-packets each with a BCH(32,24) / BCH(64,56) ECC, generator x^8 +
//   x^7 + x^6 + 1 (0x83 reflected); AVI InfoFrame (type 0x82, version 2, length 13, checksum:
//   all bytes sum to 0) at least once per two fields.
// Comparison with this IP (section 6):
//   Matches: preambles, guard bands, TERC4 island with header / sub-packet BCH, AVI InfoFrame
//   v2 fields and checksum, once per frame at the vsync leading edge, DVI mode without islands.
// Result: in line with the reference; no TODO.
```
