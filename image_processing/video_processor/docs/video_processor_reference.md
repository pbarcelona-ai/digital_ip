<!-- Industry reference check of video_processor: copied into docs/video_processor_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_processor (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
//   [2] Arm, "AMBA 4 AXI4-Stream Protocol Specification", ARM IHI 0051A (2010) / IHI 0051B
//   (2021), https://developer.arm.com/documentation/ihi0051/b - 2.2 handshake, 2.4 TKEEP /
//   TLAST
//   [3] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
//   [4] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [5] HDMI Licensing, "High-Definition Multimedia Interface Specification" 1.4b (2011)
//   5.2-5.4 (preambles, guard bands, TERC4, data island, BCH ECC) and CTA-861-G 6.4 (AVI
//   InfoFrame, checksum: all bytes sum to 0); overview https://www.prodigytechno.com/wp-
//   content/uploads/2020/01/TEK-PGY-HDMI_MHL_Application_Notes_V1.0.pdf
// Published algorithm / equations:
//   System integration follows the referenced block standards; see each block's own section 6a.
// Comparison with this IP (section 6):
//   No system-level discrepancy beyond the block TODOs (i2c_master Fast-mode tLOW affects the
//   camera CCI at 400 kHz; csi2_rx multi-packet bursts; vs_stream_adapter admission).
// Result: in line with the reference; no TODO.
```
