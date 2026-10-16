<!-- Industry reference check of axi4_lite_slave: copied into docs/axi4_lite_slave_prompt.md section 6a by ip/scripts/make_ip_prompts.py. Edit here, not in the prompt. -->
```text
// Industry reference check - axi4_lite_slave (2026-10-16)
// Sources:
//   [1] Arm, "AMBA AXI and ACE Protocol Specification", ARM IHI 0022E (2013; the last issue
//   with AXI4-Lite), https://developer.arm.com/documentation/ihi0022/e - A3.2.1 handshake,
//   A3.3.1 channel dependencies, B1 AXI4-Lite
// Published algorithm / equations:
//   AXI4-Lite: every transaction has burst length 1, data width 32 or 64, no exclusive access
//   (EXOKAY not used), WSTRB honoured. Handshake (A3.2.1): a source must not wait for READY
//   before asserting VALID; VALID stays asserted until the handshake. Dependencies (A3.3.1):
//   BVALID only after both the AW and the W handshake; RVALID only after the AR handshake.
//   Responses OKAY / SLVERR / DECERR.
// Comparison with this IP (section 6):
//   Matches: AW / W accepted independently and combined, B after both, R after AR, byte strobes
//   passed to the user, SLVERR from wr_err_i / rd_err_i, DECERR above the mapped range, one
//   transaction outstanding per direction (allowed: the slave controls READY).
// Result: in line with the reference; no TODO.
```
