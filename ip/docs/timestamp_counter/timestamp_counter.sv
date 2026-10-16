// ***************
// Filename: timestamp_counter.sv
// Author: FPGA Cores 4 U
// Description: Free-running system timestamp counter. Version 1.0.0.
//   WIDTH-bit counter incrementing on every tick_i (tie to 1 for clk
//   resolution, or use clock_enable for microseconds). clear_i zeroes it
//   and load_i loads a value. capture_i latches the count into capture_o
//   (one clock later, with cap_valid_o) so software can read a coherent
//   snapshot of a wide value; TS_CAPTURE_EDGE adds a synchronized event
//   input for external timestamping. Clock - clk. Reset - synchronous
//   active low, count 0. Latency - capture_o valid 1 clock after
//   capture_i. Rollover - wraps silently; wrap_o pulses on overflow.
//   Errors - WIDTH < 2 rejected at elaboration.
// Date: 2026-09-29

module timestamp_counter #(
  parameter int WIDTH = 64
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             tick_i,
  input  logic             clear_i,
  input  logic             load_i,
  input  logic [WIDTH-1:0] load_val_i,
  input  logic             capture_i,
  output logic [WIDTH-1:0] count_o,
  output logic [WIDTH-1:0] capture_o,
  output logic             cap_valid_o,
  output logic             wrap_o
);
