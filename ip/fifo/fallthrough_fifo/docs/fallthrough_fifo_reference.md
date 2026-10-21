<!-- Industry reference check of fallthrough_fifo: copied into docs/fallthrough_fifo_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - fallthrough_fifo (2026-10-21)
// Sources:
//   [1] C. E. Cummings, "Simulation and Synthesis Techniques for Asynchronous FIFO Design",
//   SNUG San Jose 2002, http://www.sunburst-design.com/papers/CummingsSNUG2002SJ_FIFO1.pdf -
//   section 2 (synchronous FIFO pointers: one extra bit to tell full from empty)
//   [2] Arm, "AMBA 4 AXI4-Stream Protocol Specification", ARM IHI 0051B (2021),
//   https://developer.arm.com/documentation/ihi0051/b - 2.2 handshake (a transfer when TVALID
//   and TREADY are high; TVALID must not depend on TREADY)
// Published algorithm / equations:
//   Pointers one bit wider than the address: empty when equal, full when the addresses are equal
//   and the extra bits differ; level = wptr - rptr modulo 2 * DEPTH. First-word fall-through: the
//   head word is visible without a read request; a valid / ready transfer pops it.
// Comparison with this IP (section 6):
//   Matches: the extra-bit pointers and level, power-of-two DEPTH, m_valid_o and s_ready_o from
//   the state only (neither depends on the other side's ready or valid), first-word fall-through
//   from the register array. Conservative choice: a full FIFO refuses a push even when it is
//   popped in the same clock (one clock of throughput at full, no combinational ready path).
// Result: in line with the reference; no TODO.
```
