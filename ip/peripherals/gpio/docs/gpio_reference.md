<!-- Industry reference check of gpio: copied into docs/gpio_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - gpio (2026-10-16)
// Sources:
//   [1] AMD, "AXI GPIO v2.0 Product Guide", PG144 (2016),
//   https://users.ece.utexas.edu/~mcdermot/arch/articles/Zynq/pg144-axi-gpio.pdf
//   [2] C. E. Cummings, "Clock Domain Crossing (CDC) Design & Verification Techniques Using
//   SystemVerilog", SNUG Boston 2008, http://www.sunburst-
//   design.com/papers/CummingsSNUG2008Boston_CDC.pdf
// Published algorithm / equations:
//   AMD AXI GPIO (PG144): GPIO_DATA, GPIO_TRI (1 = input), interrupt on any input transition
//   (IPISR, write 1 to clear, IPIER, GIER). Inputs from pins are synchronised with two flops
//   (Cummings).
// Comparison with this IP (section 6):
//   Matches: tri-state direction (gpio_t = 1 input), two-flop input synchronisers, edge
//   interrupts into a write-1-to-clear status, enable mask. Extensions over PG144: atomic SET /
//   CLEAR / TOGGLE and separate rising / falling enables (common in MCU GPIO). No discrepancy.
// Result: in line with the reference; no TODO.
```
