<!-- Industry reference check of ddr_ctrl: copied into docs/ddr_ctrl_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - ddr_ctrl (2026-10-25)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification" (IHI 0022, issue H), https://developer.arm.com/documentation/ihi0022
//   - A3.3.1 channel handshake dependencies (a slave may wait for AWVALID / AWREADY before WREADY,
//   for ARVALID / ARREADY before RVALID; a master must not wait for READY before VALID), A3.4 burst
//   types, sizes and lengths (INCR up to 256 beats, no 4 KB crossing: the master's rule), A3.4.4
//   responses (SLVERR, DECERR), A5 transaction IDs (one ID per read burst returned in order is legal)
//   [2] JEDEC, "DDR4 SDRAM Standard", JESD79-4 - timing tRCD, tRP, tRAS, tRTP, tWR, tWTR, tRRD, tRFC,
//   tREFI; refresh postponement (up to 8 REFs postponed, 9 x tREFI between two REFs)
//   [3] B. Jacob, S. Ng, D. Wang, "Memory Systems: Cache, DRAM, Disk" (Morgan Kaufmann, 2008), ch. 13
//   - open-page policy, row-bank-column address mapping, refresh priority over requests
// Published algorithm / equations:
//   Open-page controller: a request to the open row of its bank issues RD / WR at once (row hit),
//   to another row PRE then ACT (row miss), to a closed bank ACT; each command waits for its JEDEC
//   timings; refresh preempts requests once owed (PREA, then REF with every bank closed); every
//   tREFI one REF is due, on average one per tREFI.
// Comparison with this IP (section 6):
//   Matches: AXI4 handshakes (AWREADY / ARREADY on grant, WREADY during the burst after the
//   address - [1] A3.3.1 permits it), INCR full-width bursts, SLVERR / DECERR, in-order responses per
//   port; the open-page policy with row-bank-column mapping; every JEDEC timing rule listed (checked
//   independently by ddr_mem); refresh first with PREA / REF and the owed count, so REFs are not
//   postponed beyond the PREA timings (at most T_RAS / T_WR / T_RTP + T_RP clocks, far below the 8 x
//   tREFI postponement that [2] allows; the 15 cap is never reached for T_REFI > 2 x 254 + T_RFC).
//   Simplifications (deliberate, a generic controller for the library's frame stores and the NPU):
//   one burst at a time in grant order (no command reordering, no bank parallelism across bursts, as
//   in simple FPGA soft controllers); WLAST not checked (AxLEN counts the beats); the 4 KB rule left
//   to the masters; no narrow (AxSIZE < bus width) or WRAP / FIXED bursts (answered SLVERR); no ECC,
//   no tFAW, no self-refresh / power-down, no mode-register or ZQ sequencing (the PHY's job).
// Result: in line with the reference; no TODO.
```
