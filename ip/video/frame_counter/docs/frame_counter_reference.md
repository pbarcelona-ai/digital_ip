<!-- Industry reference check of frame_counter: copied into docs/frame_counter_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - frame_counter (2026-10-16)
// Sources:
//   [1] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   Frame markers of an AXI4-Stream video are SOF (TUSER on the first pixel) and EOL (TLAST);
//   counting frames uses one marker per frame.
// Comparison with this IP (section 6):
//   Matches: one count per marker pulse, event log with timestamps, W1C status (no algorithmic
//   standard applies).
// Result: in line with the reference; no TODO.
```
