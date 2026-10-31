<!-- Industry reference check of vs_stream_adapter: copied into docs/vs_stream_adapter_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - vs_stream_adapter (2026-10-25)
// Sources:
//   [1] Arm, "AMBA 4 AXI4-Stream Protocol Specification", ARM IHI 0051A (2010) / IHI 0051B
//   (2021), https://developer.arm.com/documentation/ihi0051/b - 2.2 handshake, 2.4 TKEEP /
//   TLAST
//   [2] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   AXI4-Stream: TVALID must not depend on TREADY (2.2.1: "a transmitter is not permitted to
//   wait until TREADY is asserted before asserting TVALID"); whole-frame drop decided at SOF
//   keeps frames intact.
// Comparison with this IP (section 6):
//   Matches: frame admission at SOF, whole-frame drop, line gaps; TVALID never depends on TREADY
//   (2026-10-25, version 1.1.0: admission from registers only - vision_system's tready of the clock
//   before (rdy_q; with vision_system idle both its routes are ready, so the sample is exact) and
//   the return FIFO; an admitted SOF is held until taken). s_axis.tready passes m_axis.tready
//   through combinationally while forwarding, as every stage of the insert loop does (allowed:
//   TREADY may depend on TVALID / TREADY downstream; no skid buffer, documented exception).
// Result: in line with the reference; no TODO (TODO(REF-VS_STREAM_ADAPTER-1) resolved).
```
