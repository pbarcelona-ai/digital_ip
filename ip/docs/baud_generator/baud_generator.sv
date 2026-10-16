// ***************
// Filename: baud_generator.sv
// Author: FPGA Cores 4 U
// Description: Programmable serial baud-rate tick generator. Version
//   1.0.0. A fractional (NCO) divider produces tick_os_o at
//   BAUD*OVERSAMPLE ticks per second and tick_baud_o once every OVERSAMPLE
//   oversample ticks, with no cumulative error (average frequency exact to
//   2^-ACC_W of the clock). The nominal increment is computed at
//   elaboration from CLK_HZ, BAUD and OVERSAMPLE; set use_reg_i=1 to
//   override it at run time with inc_i (inc =
//   round(BAUD*OVERSAMPLE*2^ACC_W/CLK_HZ)). Works at any clock frequency
//   as long as BAUD*OVERSAMPLE <= CLK_HZ/2. Clock - clk. Reset -
//   synchronous active low. sync_i restarts the bit phase (used by
//   receivers on the start edge). Latency - ticks are registered, one
//   clock after the accumulator overflows. Jitter - at most one clk period
//   on each tick. Errors - unreachable rates (increment 0 or >=
//   2^(ACC_W-1)) rejected at elaboration.
// Date: 2026-09-29

module baud_generator #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 115_200,
  parameter int OVERSAMPLE = 16,
  parameter int ACC_W      = 32
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             use_reg_i,
  input  logic [ACC_W-1:0] inc_i,
  input  logic             sync_i,          // restart accumulator and bit counter
  output logic             tick_os_o,       // oversample tick
  output logic             tick_baud_o      // one per bit time
);
