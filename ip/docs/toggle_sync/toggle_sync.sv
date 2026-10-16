// ***************
// Filename: toggle_sync.sv
// Author: FPGA Cores 4 U
// Description: Event transfer between clock domains using a toggle level.
//   Version 1.0.0. Every one-clock event_i pulse in the source domain flips a
//   toggle flop; the destination synchronizes the toggle and emits event_o
//   for each change. No handshake, so events must be spaced at least STAGES+2
//   destination clocks apart (source clock period permitting) or they are
//   lost; use pulse_sync when spacing cannot be guaranteed. Clocks - src_clk
//   and dst_clk are unrelated. Reset - synchronous per domain, active low.
//   Latency - STAGES+1 dst clocks. Errors - none reported; STAGES<2 rejected
//   at elaboration. Clock - the clock of the parent block, all signals are
//   synchronous to it.
//   synchronous to it.
// Date: 2026-09-29

module toggle_sync #(
  parameter int STAGES = 2
) (
  input  logic src_clk,
  input  logic src_rst_n,
  input  logic event_i,                  // one-clock pulse, source domain
  input  logic dst_clk,
  input  logic dst_rst_n,
  output logic event_o,                  // one-clock pulse, destination domain
  output logic toggle_o                  // synchronized toggle level (dst domain)
);
