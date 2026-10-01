// ***************
// Filename: lfsr.sv
// Author: FPGA Cores 4 U
// Description: Linear-feedback shift register / PRBS generator. Version
//   1.0.0. Fibonacci LFSR of WIDTH bits with feedback taps TAPS (bit i of
//   TAPS set means state bit i is XORed into the feedback). Defaults
//   implement PRBS7 (x^7+x^6+1, TAPS=0x60, period 127). STEPS shifts are
//   computed per enabled clock (parallel PRBS, STEPS bits per clock,
//   bit_o[STEPS-1:0] with bit 0 the oldest). load_i loads seed_i; an all-zero
//   seed (the lock-up state) is replaced by SEED and flagged on lockup_o.
//   Clock - clk. Reset - synchronous active low, state = SEED. Latency -
//   state_o updates 1 clock after en_i. Errors - WIDTH < 2, STEPS < 1, TAPS =
//   0 or SEED = 0 rejected at elaboration.
// Date: 2026-09-29
module lfsr #(
  parameter int WIDTH = 7,
  parameter logic [WIDTH-1:0] TAPS = 7'h60,
  parameter logic [WIDTH-1:0] SEED = 7'h7F,
  parameter int STEPS = 1
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             en_i,
  input  logic             load_i,
  input  logic [WIDTH-1:0] seed_i,
  output logic [WIDTH-1:0] state_o,
  output logic [STEPS-1:0] bit_o,
  output logic             lockup_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (WIDTH < 2 || STEPS < 1) begin : g_bw $error("lfsr: bad WIDTH/STEPS"); end
  if (TAPS == '0) begin : g_bt $error("lfsr: TAPS must be nonzero"); end
  if (SEED == '0) begin : g_bs $error("lfsr: SEED must be nonzero"); end
  logic [WIDTH-1:0] nxt; logic [STEPS-1:0] bits;
  always_comb begin
    logic [WIDTH-1:0] s; s = state_o;
    for (int i = 0; i < STEPS; i++) begin
      bits[i] = s[WIDTH-1];
      s = {s[WIDTH-2:0], ^(s & TAPS)};
    end
    nxt = s;
  end
  assign bit_o = bits;
  always_ff @(posedge clk) begin
    if (!rst_n) begin state_o <= SEED; lockup_o <= 1'b0; end
    else begin
      lockup_o <= 1'b0;
      if (load_i) begin
        if (seed_i == '0) begin state_o <= SEED; lockup_o <= 1'b1; end else state_o <= seed_i;
      end else if (en_i) state_o <= nxt;
    end
  end
endmodule
