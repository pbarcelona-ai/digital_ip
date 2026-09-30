// ***************
// Filename: uart_baud.sv
// Author: Paul Barcelona
// Description: Fractional baud rate generator for the UART. A phase
//   accumulator adds the tuning word every clock and its carry is the 16x
//   oversampling tick, so any baud rate can be produced at any clock
//   frequency with FCW = baud * 16 * 2^PHASE_W / f_clk. Carry output is
//   registered to keep timing short. Version 1.0.0. Helper block of its IP;
//   see the top level description for clock, reset, latency and error
//   behavior. Clock - the clock of the parent block, all signals are
//   synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
//   synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module uart_baud #(
  parameter int PHASE_W = 32
) (
  input  logic               clk,
  input  logic               rst_n,
  input  logic [PHASE_W-1:0] fcw,       // frequency control word
  output logic               tick16_o   // 16x oversample strobe
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  logic [PHASE_W-1:0] acc;
  wire  [PHASE_W:0]   sum = {1'b0, acc} + {1'b0, fcw};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      acc      <= '0;
      tick16_o <= 1'b0;
    end else begin
      acc      <= sum[PHASE_W-1:0];
      tick16_o <= sum[PHASE_W];          // carry = tick
    end
  end
endmodule
