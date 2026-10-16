<!-- Industry reference check of axil_regbus: copied into docs/axil_regbus_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axil_regbus (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
// Published algorithm / equations:
//   AXI4-Lite slave rules as above: B only after both AW and W, R after AR, payloads stable
//   while VALID is high and READY low, responses OKAY / SLVERR / DECERR.
// Comparison with this IP (section 6):
//   Matches: AW and W captured in either order, one write and one read in flight, B one clock
//   after the register write with SLVERR from reg_wr_err, R with SLVERR from reg_rd_err, R / B
//   stable while stalled.
// Result: in line with the reference; no TODO.
```
