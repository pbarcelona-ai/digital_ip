<!-- Industry reference check of scaler_ctrl: copied into docs/scaler_ctrl_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - scaler_ctrl (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
//   [2] AMD, "AXI4-Stream Video IP and System Design Guide", UG934 (2022),
//   https://www.amd.com/content/dam/amd/en/documents/products/adaptive-socs-and-
//   fpgas/technologies/axi4-stream-video-ip-and-system-design-guide.pdf - TUSER(0) = SOF on the
//   first pixel, TLAST = EOL
// Published algorithm / equations:
//   AXI4-Lite register slave (OKAY / SLVERR / DECERR) and AXI4-Stream video input with TUSER =
//   SOF on the first pixel, TLAST = EOL on the last pixel of each line (UG934).
// Comparison with this IP (section 6):
//   Matches: SOF / EOL checks (SOF_ERR / EOL_ERR), data before SOF dropped, SLVERR for read-
//   only, ID-block and unmapped words.
// Result: in line with the reference; no TODO.
```
