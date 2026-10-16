<!-- Industry reference check of mulq: copied into docs/mulq_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - mulq (2026-10-16)
// Sources:
//   [1] B. Parhami, "Computer Arithmetic", 2nd ed., ch. 9-11 (partial-product decomposition of
//   wide multipliers: a*b = sum of 16x16 partial products shifted by 0 / 16 / 32)
// Published algorithm / equations:
//   Wide multiplication by partial products: a*b = (aH bH << 32) + ((aH bL + aL bH) << 16) + aL
//   bL; Q16.16 product = (a*b) >>> 16.
// Comparison with this IP (section 6):
//   Matches: four 16x16 partial products in DSPs, combined in a second stage, exact 48-bit
//   result.
// Result: in line with the reference; no TODO.
```
