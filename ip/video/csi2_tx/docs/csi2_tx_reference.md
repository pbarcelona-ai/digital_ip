<!-- Industry reference check of csi2_tx: copied into docs/csi2_tx_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - csi2_tx (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
// Published algorithm / equations:
//   CSI-2 frame: Frame Start short packet (data = frame number, non-zero, incrementing), one
//   long packet per line, Frame End short packet with the same frame number; RGB888 = data type
//   0x24, YUV422 8-bit 0x1E; virtual channel in DI[7:6].
// Comparison with this IP (section 6):
//   Matches: FS / FE with frame number 1..65535, one long packet per line, data types and byte
//   orders, VC in the DI, LP between packets (allowed).
// Result: in line with the reference; no TODO.
```
