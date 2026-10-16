<!-- Industry reference check of mipi_tx_engine: copied into docs/mipi_tx_engine_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - mipi_tx_engine (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [2] MIPI Alliance, "Specification for Display Serial Interface (DSI)" v1.3: 8.11 video mode
//   (non-burst with sync events: VSS 0x01, HSS 0x21, no HSE / VSE), 8.8 data types (packed
//   pixel stream 24-bit 0x3E R,G,B; DCS short write 0x05 / 0x15, DCS long write 0x39), EoTp 08
//   0F 0F 01; summary TI SNLA356 https://www.ti.com/document-
//   viewer/lit/html/SNLA356/GUID-2F47E337-61D9-405B-8259-99385DB44B8A
//   [3] MIPI Alliance, "D-PHY Specification" v1.2 PPI (TxRequestHS / TxReadyHS / TxDataHS);
//   vendor tables Intel
//   https://www.intel.com/content/www/us/en/docs/programmable/817561/25-1/d-phy-tx-ppi-
//   interface-signals.html and AMD PG436 https://docs.amd.com/r/en-US/pg436-mipi-tx-phy/PPI-
//   Signals
// Published algorithm / equations:
//   CSI-2 / DSI low level protocol: short packet = DI, 16-bit data, ECC; long packet = DI, WC,
//   ECC, WC payload bytes, 16-bit checksum (CRC-16 CCITT x^16 + x^12 + x^5 + 1, initial 0xFFFF,
//   data LSB first, sent LSB byte first); 6-bit Hamming ECC over the 24 header bits (bits 7:6
//   zero in v1.x); bytes distributed round-robin over the lanes; a packet is sent within one HS
//   burst (PPI: TxRequestHS, TxReadyHS, one byte per lane per byte clock). DSI EoTp = 08 0F 0F
//   01.
// Comparison with this IP (section 6):
//   Matches: header ECC, CRC-16 parameters, byte-to-lane distribution, PPI handshake, EoTp
//   bytes, RGB888 byte orders (CSI-2 B,G,R; DSI R,G,B), YUV422 8-bit U,Y,V,Y. Long-command
//   limit (64 bytes) is an implementation limit (the specifications allow WC up to 65535).
// Result: in line with the reference; no TODO.
```
