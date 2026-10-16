// ***************
// Filename: interval_timer.sv
// Author: FPGA Cores 4 U
// Description: Programmable interval timer. Version 1.0.0. Counts
//   prescaled ticks and raises a one-clock irq_o / tick_o every interval_i
//   ticks. AUTO_RELOAD mode repeats forever; one-shot mode (auto_i=0)
//   stops after the first event. Prescaler divides clk by prescale_i+1.
//   start_i starts (or restarts) the timer, stop_i halts it, and
//   remaining_o shows the ticks left. The interval and prescaler may be
//   rewritten while running and take effect at the next reload. Clock -
//   clk. Reset - synchronous active low, stopped. Latency - first event
//   interval*(prescale+1) clocks after start_i. Errors - interval_i = 0 is
//   invalid: start is refused and err_o pulses.
// Date: 2026-09-29

module interval_timer #(
  parameter int WIDTH   = 32,
  parameter int PRES_W  = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,
  input  logic              stop_i,
  input  logic              auto_i,           // 1 = auto reload
  input  logic [WIDTH-1:0]  interval_i,
  input  logic [PRES_W-1:0] prescale_i,
  output logic              running_o,
  output logic              tick_o,           // one clock per interval
  output logic [WIDTH-1:0]  remaining_o,
  output logic              err_o             // start refused (interval 0)
);
