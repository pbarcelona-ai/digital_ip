<!-- Industry reference check of fixed_recip: copied into docs/fixed_recip_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - fixed_recip (2026-10-16)
// Sources:
//   [1] B. Parhami, "Computer Arithmetic: Algorithms and Hardware Designs", 2nd ed., Oxford
//   2010, 13.3 restoring division (one quotient bit per cycle: shift, trial subtract, restore
//   when negative); slides https://www.ece.ucdavis.edu/~vojin/CLASSES/EPFL/Lectures/VLSI-
//   Arithmetic-Lect-11-Division.pdf
// Published algorithm / equations:
//   Restoring division: one quotient bit per cycle (shift the partial remainder, trial
//   subtract, keep or restore), n cycles for an n-bit quotient.
// Comparison with this IP (section 6):
//   Matches: iterative shift / subtract, 33 cycles for a Q16.16 reciprocal (32 quotient bits +
//   setup).
// Result: in line with the reference; no TODO.
```
