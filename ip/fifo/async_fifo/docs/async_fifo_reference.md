<!-- Industry reference check of async_fifo: copied into docs/async_fifo_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - async_fifo (2026-10-16)
// Sources:
//   [1] C. E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design",
//   SNUG San Jose 2002, http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf
// Published algorithm / equations:
//   Cummings 2002 (FIFO1, style #1): pointers one bit wider than the address, binary and Gray
//   copies; the Gray write pointer crosses into rclk through two flops (empty = rptr_gray ==
//   synced wptr_gray, computed on the next pointer value and registered) and the Gray read
//   pointer into wclk (full = the two MSBs inverted, the rest equal); flags are pessimistic,
//   never optimistic. DEPTH a power of two.
// Comparison with this IP (section 6):
//   Matches: Gray pointers, two-flop synchronisers, registered full / empty, power-of-two
//   DEPTH, conservative flags, per-domain resets asserted together. Additions: block-RAM
//   storage with registered read and a first-word-fall-through output register (adds read-side
//   latency, 3 to 5 clocks).
// Result: in line with the reference; no TODO.
```
