<!-- Industry reference check of mipi_line_buf: copied into docs/mipi_line_buf_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - mipi_line_buf (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [2] C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using
//   SystemVerilog", SNUG Boston 2008, http://www.sunburst-
//   design.com/papers/CummingsSNUG2008Boston_CDC.pdf
// Published algorithm / equations:
//   An HS burst cannot pause, so a transmitter buffers a whole line before starting its long
//   packet; buffer ownership crosses clock domains with handshakes (Cummings).
// Comparison with this IP (section 6):
//   Matches: ping-pong line buffers, whole line before the burst, free indications through
//   pulse_sync.
// Result: in line with the reference; no TODO.
```
