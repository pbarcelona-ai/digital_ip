<!-- Industry reference check of video_pipeline: copied into docs/video_pipeline_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - video_pipeline (2026-10-16)
// Sources:
//   [1] MIPI Alliance, "Specification for Camera Serial Interface 2 (CSI-2)" v1.3 (2014):
//   9.1-9.6 low level protocol (DI, WC, 6-bit header ECC, CRC-16 x^16+x^12+x^5+1 seed 0xFFFF),
//   11 data formats (RGB888 0x24 B,G,R; YUV422 8-bit 0x1E U,Y,V,Y; RAW8 0x2A, RAW10 0x2B, RAW12
//   0x2C); vendor summary AMD PG232 https://docs.amd.com/r/5.1-English/pg232-mipi-csi2-rx/MIPI-
//   CSI-2-RX-Controller
//   [2] R. Ramanath, W. E. Snyder, Y. Yoo, M. S. Drew, "Color image processing pipeline", IEEE
//   Signal Processing Magazine 22(1):34-43, 2005, doi:10.1109/MSP.2005.1407713 (black level,
//   white balance, demosaicking, colour transform, tone curve)
//   [3] HDMI Licensing, "High-Definition Multimedia Interface Specification" 1.4b (2011)
//   5.2-5.4 (preambles, guard bands, TERC4, data island, BCH ECC) and CTA-861-G 6.4 (AVI
//   InfoFrame, checksum: all bytes sum to 0); overview https://www.prodigytechno.com/wp-
//   content/uploads/2020/01/TEK-PGY-HDMI_MHL_Application_Notes_V1.0.pdf
//   [4] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   Camera ISP chain order (Ramanath 2005): black level -> defect correction -> white balance
//   -> demosaic -> colour correction -> tone curve -> colour space conversion; then scaling and
//   display link.
// Comparison with this IP (section 6):
//   Matches: csi2_rx -> raw unpack -> BLC / WB -> DPC -> demosaic -> CCM -> gamma -> CSC ->
//   scaler -> outputs (HDMI / LVDS / DSI / CSI-2). Note: DPC runs after WB here (industry
//   chains usually correct defects before WB); the result is the same for clamp-based DPC as
//   long as the WB gains are applied to all colours equally in the comparison, so this is
//   documented, not changed.
// RESOLVED(REF-VIDEO_PIPELINE-1) [LOW] DPC placement. Resolution: 2026-10-21: the video_pipeline.sv header states that DPC follows BLC / WB (DPC_THR in
//   white-balanced units) and that with unity gains, as in video_processor, the order makes no difference.
```
