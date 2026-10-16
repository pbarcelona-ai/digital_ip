<!-- Industry reference check of axil_split: copied into docs/axil_split_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axil_split (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
// Published algorithm / equations:
//   An AXI4-Lite interconnect (1 master, N slaves) routes each transaction by address and
//   returns the slave response unchanged; AW / W may arrive in any order; transactions to one
//   slave complete in order.
// Comparison with this IP (section 6):
//   Matches: routing by address bit SEL_BIT (two windows that tile the space, so no DECERR
//   region exists), AW / W held until both present, responses passed back unchanged, one write
//   and one read in flight.
// Result: in line with the reference; no TODO.
```
