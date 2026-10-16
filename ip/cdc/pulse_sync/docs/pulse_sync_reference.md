<!-- Industry reference check of pulse_sync: copied into docs/pulse_sync_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - pulse_sync (2026-10-16)
// Sources:
//   [1] C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using
//   SystemVerilog", SNUG Boston 2008, http://www.sunburst-
//   design.com/papers/CummingsSNUG2008Boston_CDC.pdf
// Published algorithm / equations:
//   Cummings 2008 section 5.7-5.8: a pulse crosses as a toggle (level change) through a two-
//   flop synchroniser and is re-created by an XOR edge detector; closed-loop: an acknowledge
//   toggle returns so the sender knows when it may send the next pulse.
// Comparison with this IP (section 6):
//   Matches: toggle + edge detector, acknowledge toggle back, busy_o while in flight. Pulses
//   during busy are dropped and flagged (drop_o) - the paper requires the sender to wait;
//   flagging is the safe extension.
// Result: in line with the reference; no TODO.
```
