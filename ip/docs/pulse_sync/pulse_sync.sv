// ***************
// Filename: pulse_sync.sv
// Author: FPGA Cores 4 U
// Description: Pulse transfer between clock domains with full handshake.
//   Version 1.0.0. A toggle crosses to the destination and an acknowledge
//   toggle crosses back, so a new pulse is accepted only when the previous
//   one has completed (busy_o low). Pulses arriving while busy are dropped
//   and flagged on drop_o (one src clock) so nothing is lost silently. Clocks
//   - src_clk and dst_clk unrelated. Reset - synchronous per domain, active
//   low. Latency - about STAGES+2 dst clocks to pulse_o; busy clears after
//   ~2*STAGES+3 clocks of the slower domain. Errors - drop_o on overrun;
//   STAGES<2 rejected at elaboration. Clock - the clock of the parent block,
//   all signals are synchronous to it.
//   all signals are synchronous to it.
// Date: 2026-09-29

module pulse_sync #(
  parameter int STAGES = 2
) (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic pulse_i,                  // one-clock pulse, source domain
  output logic busy_o,                   // transfer in flight (source domain)
  output logic drop_o,                   // pulse_i ignored because busy
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic pulse_o                   // one-clock pulse, destination domain
);
