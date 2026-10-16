<!-- Industry reference check of axis_to_video: copied into docs/axis_to_video_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axis_to_video (2026-10-16)
// Sources:
//   [1] AMD, "AXI4-Stream to Video Out" PG044 (stream to timed video with a timing controller,
//   locked / underflow handling), https://docs.amd.com/r/en-US/pg044_v_axis_vid_out
//   [2] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   AMD AXI4-Stream to Video Out (PG044): a FIFO bridges the stream to a timing generator; the
//   output locks to SOF (TUSER), counts EOL (TLAST), reports underflow and re-locks at the next
//   SOF.
// Comparison with this IP (section 6):
//   Matches: FIFO, lock to SOF with start level, underflow detection, resync to the next SOF,
//   black output while unlocked, colour-bar test pattern.
// Result: in line with the reference; no TODO.
```
