// ***************
// Filename: quad_bfm.sv
// Author: FPGA Cores 4 U
// Description: Incremental (quadrature) encoder bus functional model:
//   A, B and index (Z) outputs, timed in cycles of clk.
//   step() moves one quadrature state forward (00 -> 10 -> 11 -> 01 -> 00,
//   A leads) or backward and holds it; glitch_a() inverts A for a few
//   cycles (must be filtered); jump() sets A and B at once (an illegal
//   double transition when both bits change) and takes that as the new
//   state; index() pulses Z.
// Date: 2026-10-09
`timescale 1ns/1ps

module quad_bfm (
  input  logic clk,                           // timing reference
  output logic a,
  output logic b,
  output logic z
);
  int st = 0;                                 // quadrature state 0..3 (00, 10, 11, 01)
  initial begin
    a = 0;
    b = 0;
    z = 0;
  end

  task automatic step(input bit fwd, input int hold);
    st = fwd ? (st + 1) % 4 : (st + 3) % 4;
    case (st)
      0: {a, b} = 2'b00;
      1: {a, b} = 2'b10;
      2: {a, b} = 2'b11;
      3: {a, b} = 2'b01;
    endcase
    repeat (hold) @(posedge clk);
  endtask

  task automatic glitch_a(input int clks);
    a = ~a;
    repeat (clks) @(posedge clk);
    a = ~a;
  endtask

  task automatic jump(input logic [1:0] ab, input int hold);
    {a, b} = ab;
    repeat (hold) @(posedge clk);
    case (ab)
      2'b00: st = 0;
      2'b10: st = 1;
      2'b11: st = 2;
      2'b01: st = 3;
    endcase
  endtask

  task automatic index(input int clks);
    z = 1;
    repeat (clks) @(posedge clk);
    z = 0;
  endtask
endmodule
