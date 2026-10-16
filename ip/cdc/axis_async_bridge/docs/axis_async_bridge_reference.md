<!-- Industry reference check of axis_async_bridge: copied into docs/axis_async_bridge_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axis_async_bridge (2026-10-16)
// Sources:
//   [1] C. E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design",
//   SNUG San Jose 2002, http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf
//   [2] Arm, "AMBA 4 AXI4-Stream Protocol Specification", ARM IHI 0051A (2010) / IHI 0051B
//   (2021), https://developer.arm.com/documentation/ihi0051/b - 2.2 handshake, 2.4 TKEEP /
//   TLAST
//   [3] C. E. Cummings, D. Mills, S. Golson, "Asynchronous & Synchronous Reset Design
//   Techniques - Part Deux", SNUG Boston 2003,
//   https://docenti.ing.unipi.it/~a011468/didattica/SE/Ppt/CummingsSNUG2003Boston_Resets.pdf
// Published algorithm / equations:
//   Cummings 2002 style #1 asynchronous FIFO: binary + Gray pointers, Gray pointers cross
//   through two flops, full in the write domain (MSBs inverted compare), empty in the read
//   domain; resets asserted asynchronously and released synchronously per domain (Cummings
//   2003). AXI4-Stream: TKEEP has DATA_W / 8 bits, TLAST / TUSER travel with the beat.
// Comparison with this IP (section 6):
//   Matches: built on async_fifo (Gray pointers, two-flop crossings, conservative flags), per-
//   domain reset synchronisers (async assert, sync release), tdata / tkeep / tlast / tuser
//   carried together, DATA_W multiple of 8 checked.
// Result: in line with the reference; no TODO.
```
