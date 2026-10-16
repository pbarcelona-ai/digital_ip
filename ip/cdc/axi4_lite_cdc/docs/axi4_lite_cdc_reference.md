<!-- Industry reference check of axi4_lite_cdc: copied into docs/axi4_lite_cdc_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axi4_lite_cdc (2026-10-16)
// Sources:
//   [1] C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using
//   SystemVerilog", SNUG Boston 2008, http://www.sunburst-
//   design.com/papers/CummingsSNUG2008Boston_CDC.pdf
//   [2] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
// Published algorithm / equations:
//   Cummings 2008 section 5.6-5.8: a multi-bit bus crosses safely when it is held stable and a
//   single control bit (toggle / pulse) crosses through a two-flop synchroniser, with an
//   acknowledge returned the same way ("MCP formulation with feedback"). AXI rules as for
//   axi4_lite_slave.
// Comparison with this IP (section 6):
//   Matches: toggle request / acknowledge with two-flop synchronisers, address / data /
//   response held stable while the toggle crosses (multi-cycle path), one transaction
//   outstanding, responses passed back unchanged. The write-before-read ordering on a same-
//   clock collision is a documented choice (AXI does not order reads against writes).
// Result: in line with the reference; no TODO.
```
