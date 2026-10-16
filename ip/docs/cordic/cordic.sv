// ***************
// Filename: cordic.sv
// Author: FPGA Cores 4 U
// Description: Pipelined CORDIC. Version 1.0.0. MODE 0 (rotation) rotates
//   the vector (x_i, y_i) by the angle z_i, giving x*cos-y*sin and
//   x*sin+y*cos (with x_i=A, y_i=0 it is a sine/cosine generator of
//   amplitude A); MODE 1 (vectoring) returns the magnitude sqrt(x^2+y^2)
//   in mag_o and the angle atan2(y,x) in z_o. Angles are unsigned turns -
//   z is ZW bits and 2^ZW equals 2*pi, so the phase word of an NCO
//   connects directly. Full-circle range is handled by a quadrant pre-
//   rotation, the CORDIC gain (1.6468) is compensated by a constant
//   multiplier, and WIDTH+2 guard bits are used internally. One result per
//   clock (fully pipelined), ITER micro-rotations. Clock - clk with
//   valid_i/valid_o. Reset - synchronous active low clears the valid
//   pipeline (data registers are unreset, valid_o=0 masks them). Latency -
//   ITER+2 clocks. Accuracy - about 2 LSB in rotation mode and 2 LSB plus
//   2^-ITER rad in vectoring mode; inputs must satisfy |(x,y)| <=
//   2^(WIDTH-1)-1 (rotation) so results fit; magnitude output has WIDTH+1
//   bits. Errors - out-of-range parameters rejected at elaboration.
// Date: 2026-09-29

module cordic #(
  parameter int WIDTH = 16,             // x, y width (signed)
  parameter int ZW    = 16,             // angle width (unsigned turns)
  parameter int ITER  = 16,             // micro-rotations (<= 30)
  parameter int MODE  = 0               // 0 rotation, 1 vectoring
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     valid_i,
  input  logic signed [WIDTH-1:0]  x_i,
  input  logic signed [WIDTH-1:0]  y_i,
  input  logic        [ZW-1:0]     z_i,          // rotation angle (MODE 0)
  output logic                     valid_o,
  output logic signed [WIDTH-1:0]  x_o,          // MODE 0: rotated x
  output logic signed [WIDTH-1:0]  y_o,          // MODE 0: rotated y
  output logic        [WIDTH:0]    mag_o,        // MODE 1: magnitude
  output logic        [ZW-1:0]     z_o           // MODE 1: angle in turns
);
