// ***************
// Filename: edge_detect.sv
// Author: FPGA Cores 4 U
// Description: Edge detector for WIDTH signals. Version 1.0.0. EDGE
//   selects rising (0), falling (1) or both (2). Optional two-flop input
//   synchronizer (SYNC_INPUT=1) for asynchronous inputs. Clock - clk;
//   input must be synchronous unless SYNC_INPUT=1. Reset - synchronous
//   active low, previous-value register resets to RESET_LEVEL so no false
//   edge appears after reset. Latency - pulse_o is registered: 1 clock
//   after the input changes (3 with SYNC_INPUT). Output - one clock wide
//   pulse. Errors - invalid EDGE or WIDTH rejected at elaboration.
// Date: 2026-09-29

module edge_detect #(
  parameter int WIDTH       = 1,
  parameter int EDGE        = 0,         // 0 rise, 1 fall, 2 both
  parameter bit SYNC_INPUT  = 1'b0,
  parameter bit RESET_LEVEL = 1'b0       // assumed idle input level
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] pulse_o
);
