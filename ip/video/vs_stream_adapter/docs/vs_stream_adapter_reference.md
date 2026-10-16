<!-- Industry reference check of vs_stream_adapter: copied into docs/vs_stream_adapter_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - vs_stream_adapter (2026-10-16)
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
//   Matches: frame admission at SOF, whole-frame drop, line gaps. Open item from the code
//   review: admission currently looks at the downstream tready (to be replaced by a vs_idle_i
//   status, see code_reviews/vs_stream_adapter.sv_review.txt).
// TODO(REF-VS_STREAM_ADAPTER-1) [MEDIUM] Admission must not use tready. Prompt: in
//   ip/video/vs_stream_adapter/src/vs_stream_adapter.sv, decide frame admission from a
//   registered vision_system idle status input (vs_idle_i) and the return FIFO level instead of
//   m_axis_tready, so TVALID never depends on TREADY (IHI 0051 2.2.1); add a ready skid buffer
//   and update video_processor.sv to connect vision_system's idle status.
```
