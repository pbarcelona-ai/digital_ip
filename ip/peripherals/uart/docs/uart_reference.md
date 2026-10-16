<!-- Industry reference check of uart: copied into docs/uart_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - uart (2026-10-16)
// Sources:
//   [1] Texas Instruments, "TL16C550C Asynchronous Communications Element", SLLS177H (2006),
//   https://www.ti.com/product/TL16C550C - baud = f_clk / (16 x divisor), mid-bit sampling
// Published algorithm / equations:
//   16550 UART: baud = f_clk / (16 x divisor); the receiver detects the start bit falling edge,
//   checks it again at mid-bit (rejects glitches) and samples each data bit at mid-bit (16x
//   oversampling); 5-8 data bits, optional even / odd / stick parity, 1 / 1.5 / 2 stop bits;
//   framing error when the stop bit is 0, break when the line stays low for a whole character.
// Comparison with this IP (section 6):
//   Matches: 16x oversampled receiver with mid-bit start qualification and mid-bit sampling,
//   5-8 bits, parity, stop-bit check, framing / parity errors, FIFOs. Differs: baud from a
//   fractional accumulator (FCW, finer than the 16550 integer divisor - an improvement); only 1
//   or 2 stop bits.
// Result: in line with the reference; no TODO.
```
