<!-- Industry reference check of clk_gen: copied into docs/clk_gen_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - clk_gen (2026-10-16)
// Sources:
//   [1] R. B. Staszewski, P. T. Balsara, "All-Digital Frequency Synthesizer in Deep-Submicron
//   CMOS", Wiley 2006; seminar notes
//   https://ewh.ieee.org/soc/cas/dallas/documents/2004-10-19_DallasCASSeminar.pdf (TDC phase
//   detector, digital PI loop filter, DCO)
// Published algorithm / equations:
//   Frequency synthesis with cascaded PLLs: f_out = f_ref * M / (D * O); outputs of one
//   oscillator are phase aligned; FPGA practice is the device PLL / MMCM with BUFGCE glitch-
//   free gating (CE synchronised to the gated clock or CE_TYPE = ASYNC).
// Comparison with this IP (section 6):
//   Matches: f(clk_o[n]) = REF * CPU_M * CLK_M / (CPU_D * CPU_O * CLK_D * CLK_O[n]), shared
//   oscillator for related outputs, glitch-free enables, lock-gated release, FPGA replacement
//   documented.
// Result: in line with the reference; no TODO.
```
