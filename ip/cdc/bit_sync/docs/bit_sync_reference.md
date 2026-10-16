<!-- Industry reference check of bit_sync: copied into docs/bit_sync_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - bit_sync (2026-10-16)
// Sources:
//   [1] C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using
//   SystemVerilog", SNUG Boston 2008, http://www.sunburst-
//   design.com/papers/CummingsSNUG2008Boston_CDC.pdf
// Published algorithm / equations:
//   Cummings 2008 section 4: a single-bit asynchronous level is sampled by two (or three, for
//   higher MTBF) flip-flops with no logic between them; MTBF = e^(tr/tau) / (Tw f_clk f_data);
//   the input must be glitch free (registered in its source domain) and wide enough to be
//   sampled.
// Comparison with this IP (section 6):
//   Matches: STAGES >= 2 flops, async_reg attribute, no logic between stages, requirement that
//   d_i is glitch free and held for one clk period documented.
// Result: in line with the reference; no TODO.
```
