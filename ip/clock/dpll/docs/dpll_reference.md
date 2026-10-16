<!-- Industry reference check of dpll: copied into docs/dpll_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - dpll (2026-10-16)
// Sources:
//   [1] R. B. Staszewski, P. T. Balsara, "All-Digital Frequency Synthesizer in Deep-Submicron
//   CMOS", Wiley 2006; seminar notes
//   https://ewh.ieee.org/soc/cas/dallas/documents/2004-10-19_DallasCASSeminar.pdf (TDC phase
//   detector, digital PI loop filter, DCO)
//   [2] M. Robertson, "Modeling a PLL" / digital type-2 PLL loop gains,
//   https://www.dsprelated.com/showarticle/973.php; F. M. Gardner, "Phaselock Techniques", 3rd
//   ed., Wiley 2005 - zeta = Kp / (2 sqrt(Ki)) (normalised gains)
// Published algorithm / equations:
//   ADPLL (Staszewski): a time-to-digital converter measures the phase error, a digital
//   proportional-integral loop filter tunes a digitally controlled oscillator (type-2, second-
//   order loop). Damping zeta = Kp / (2 sqrt(Ki)) with gains normalised per reference cycle;
//   zeta 0.7 .. 1 is the usual choice.
// Comparison with this IP (section 6):
//   Matches: TDC phase read-out, PI loop filter, DCO, lock detector. Check of the stated gains:
//   Kp = 1/32, Ki = Kp/64 = 1/2048 gives zeta = (1/32) / (2 sqrt(1/2048)) = 0.71; Kp = 1/16, Ki
//   = 1/1024 gives zeta = 1.0 - the header's "damping 0.7 .. 1" agrees with the standard
//   formula.
// Result: in line with the reference; no TODO.
```
