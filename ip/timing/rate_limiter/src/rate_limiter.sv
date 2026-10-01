// ***************
// Filename: rate_limiter.sv
// Author: FPGA Cores 4 U
// Description: Token-bucket rate limiter for valid/ready streams or events.
//   Version 1.0.0. One token is added every refill_period_i clocks up to a
//   bucket size of burst_i; each transferred word (s_valid_i & s_ready_o)
//   consumes one token. When the bucket is empty s_ready_o is low, so the
//   average rate is 1/refill_period_i words per clock with bursts up to
//   burst_i. Data passes combinationally between s_* and m_* (no added
//   latency, no storage). refill_period_i = 0 disables limiting. Clock - clk.
//   Reset - synchronous active low, bucket full. Errors - none; a downstream
//   stall (m_ready_i low) does not consume tokens. TOKEN_W < 2 rejected at
//   elaboration. Latency - as documented in the parent block, fixed and
//   independent of data.
//   independent of data.
// Date: 2026-09-29
module rate_limiter #(
  parameter int DATA_W  = 32,
  parameter int TOKEN_W = 8,
  parameter int PERIOD_W = 16
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [PERIOD_W-1:0] refill_period_i,   // clocks per token, 0 = unlimited
  input  logic [TOKEN_W-1:0]  burst_i,           // bucket capacity
  input  logic [DATA_W-1:0]   s_data_i,
  input  logic                s_valid_i,
  output logic                s_ready_o,
  output logic [DATA_W-1:0]   m_data_o,
  output logic                m_valid_o,
  input  logic                m_ready_i,
  output logic [TOKEN_W-1:0]  tokens_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (TOKEN_W < 2 || PERIOD_W < 1) begin : g_bad $error("rate_limiter: bad widths"); end
  logic [PERIOD_W-1:0] pc; logic [TOKEN_W-1:0] tok;
  wire unlimited = (refill_period_i == '0);
  wire have_tok  = (tok != '0) | unlimited;
  assign m_data_o  = s_data_i;
  assign m_valid_o = s_valid_i & have_tok;
  assign s_ready_o = m_ready_i & have_tok;
  wire   xfer      = s_valid_i & s_ready_o;
  wire   refill    = (pc >= refill_period_i - 1'b1) & ~unlimited;
  always_ff @(posedge clk) begin
    if (!rst_n) begin pc <= '0; tok <= burst_i; end
    else begin
      if (refill || unlimited) pc <= '0; else pc <= pc + 1'b1;
      case ({refill && tok < burst_i, xfer && !unlimited})
        2'b10: tok <= tok + 1'b1;
        2'b01: tok <= tok - 1'b1;
        default: ;
      endcase
      if (tok > burst_i) tok <= burst_i;              // burst_i reduced at run time
    end
  end
  assign tokens_o = tok;
endmodule
