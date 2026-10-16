<!-- Industry reference check of csi2_rx: copied into docs/csi2_rx_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - csi2_rx (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [2] MIPI Alliance, "D-PHY Specification" v1.2 PPI (TxRequestHS / TxReadyHS / TxDataHS);
//   vendor tables Intel
//   https://www.intel.com/content/www/us/en/docs/programmable/817561/25-1/d-phy-tx-ppi-
//   interface-signals.html and AMD PG436 https://docs.amd.com/r/en-US/pg436-mipi-tx-phy/PPI-
//   Signals
// Published algorithm / equations:
//   CSI-2 receiver: lane merging, header ECC (correct 1 bit, detect 2), CRC-16 check, Frame
//   Start / End (0x00 / 0x01), Line Start / End (0x02 / 0x03, optional), long packets by data
//   type; a transmitter may send several packets in one HS burst (packets back to back, each
//   with its own header).
// Comparison with this IP (section 6):
//   Matches: deskew, ECC correction / detection, CRC check, FS / FE, data-type and VC
//   filtering. Differs: only the first packet of each HS burst is decoded; bytes after its
//   checksum are ignored, so a sensor that sends several packets per burst (allowed by CSI-2)
//   loses the later ones.
// TODO(REF-CSI2_RX-1) [MEDIUM] Several packets per burst. Prompt: in
//   ip/video/csi2_rx/src/csi2_rx.sv, after a long packet's checksum (or a short packet's
//   header) return to the header state while lane_valid stays high, so back-to-back packets in
//   one HS burst are all decoded (skip any filler bytes the PHY inserts before EoT); add a
//   testbench test with FS + two lines + FE in one burst and with two lines per burst.
```
