// ***************
// Filename: clock_domain_bridge.sv
// Author: Paul Barcelona
// Description: Generic clock-domain bridge for multi-bit words using a four-
//   phase toggle handshake. Version 1.0.0. A word accepted on the source
//   valid/ready interface is held in a source register while a request toggle
//   crosses to the destination (bit_sync); the destination copies the word
//   into its own output register (data is stable, so the multi-bit capture is
//   safe), presents it on the destination valid/ready interface and, when it
//   is taken, returns an acknowledge toggle. The source is ready again only
//   after the acknowledge has been synchronized back, so at most one word is
//   in flight and words are never lost, duplicated or reordered. Clocks -
//   s_clk and m_clk unrelated, any ratio. Reset - synchronous per domain,
//   active low; reset both domains together (or hold the slower one longer).
//   Latency - about 2*STAGES+3 clocks of the slower domain per word.
//   Throughput - one word per round trip (low), use async_fifo for streaming.
//   Timing - the data register to destination register path is a false path
//   or a max-delay constraint of one destination period; no combinational
//   logic on it. Errors - STAGES < 2 or DATA_W < 1 rejected at elaboration.
//   Clock - the clock of the parent block, all signals are synchronous to it.
// Date: 2026-09-29
module clock_domain_bridge #(
  parameter int DATA_W = 32,
  parameter int STAGES = 2
) (
  input  logic              s_clk,
  input  logic              s_rst_n,
  input  logic [DATA_W-1:0] s_data_i,
  input  logic              s_valid_i,
  output logic              s_ready_o,
  input  logic              m_clk,
  input  logic              m_rst_n,
  output logic [DATA_W-1:0] m_data_o,
  output logic              m_valid_o,
  input  logic              m_ready_i
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (STAGES < 2) begin : g_bs $error("clock_domain_bridge: STAGES must be >= 2"); end
  if (DATA_W < 1) begin : g_bw $error("clock_domain_bridge: DATA_W must be >= 1"); end
  logic [DATA_W-1:0] hold; logic req_tog, ack_tog, ack_s, req_s;
  bit_sync #(.STAGES(STAGES)) u_ack (.clk(s_clk), .rst_n(s_rst_n), .d_i(ack_tog), .q_o(ack_s));
  assign s_ready_o = (req_tog == ack_s);
  always_ff @(posedge s_clk) begin
    if (!s_rst_n) begin req_tog <= 1'b0; hold <= '0; end
    else if (s_valid_i & s_ready_o) begin hold <= s_data_i; req_tog <= ~req_tog; end
  end
  bit_sync #(.STAGES(STAGES)) u_req (.clk(m_clk), .rst_n(m_rst_n), .d_i(req_tog), .q_o(req_s));
  always_ff @(posedge m_clk) begin
    if (!m_rst_n) begin m_valid_o <= 1'b0; m_data_o <= '0; ack_tog <= 1'b0; end
    else if (!m_valid_o) begin
      if (req_s != ack_tog) begin m_valid_o <= 1'b1; m_data_o <= hold; end
    end else if (m_ready_i) begin
      m_valid_o <= 1'b0; ack_tog <= ~ack_tog;
    end
  end
endmodule
