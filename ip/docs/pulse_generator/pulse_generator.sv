// ***************
// Filename: pulse_generator.sv
// Author: FPGA Cores 4 U
// Description: Periodic or one-shot pulse generator. Version 1.0.0. In
//   continuous mode a pulse of width_i clocks is produced every period_i
//   clocks; in one-shot mode (oneshot_i=1) each trigger_i pulse produces
//   one pulse of width_i clocks (retriggers ignored while active). Period,
//   width and polarity may be changed on the fly; new values apply from
//   the next period start. width_i is clamped to period_i in continuous
//   mode. Clock - clk. Reset - synchronous active low, output idle
//   (inverted when INVERT). Latency - pulse_o starts 1 clock after the
//   period start or trigger. Errors - period_i = 0 disables output;
//   width_i = 0 gives no pulse; WIDTH < 2 rejected at elaboration.
// Date: 2026-09-29

module pulse_generator #(
  parameter int WIDTH  = 16,
  parameter bit INVERT = 1'b0
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             oneshot_i,
  input  logic             trigger_i,
  input  logic [WIDTH-1:0] period_i,      // clocks per period (continuous mode)
  input  logic [WIDTH-1:0] width_i,       // pulse width in clocks
  output logic             pulse_o,
  output logic             start_o        // one clock at the start of each pulse
);
