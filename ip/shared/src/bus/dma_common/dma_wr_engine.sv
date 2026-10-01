// ***************
// Filename: dma_wr_engine.sv
// Author: FPGA Cores 4 U
// Description: AXI4 write burst engine for the DMA IPs. Consumes an AXI-
//   Stream of 32-bit words and writes NWORDS words to a word-aligned address
//   using INCR bursts of up to MAX_BURST beats that never cross a 4 KB
//   boundary. Completion is reported after the last write response. Sticky
//   error flag when any write response is not OKAY. Version 1.0.0. Helper
//   block of its IP; see the top level description for clock, reset, latency
//   and error behavior. Clock - the clock of the parent block, all signals
//   are synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
//   are synchronous to it. Reset - synchronous, driven by the parent block.
//   Latency - as documented in the parent block, fixed and independent of
//   data. Errors - none reported here, out-of-range parameters stop
//   elaboration or are handled by the parent block.
// Date: 2026-09-29
module dma_wr_engine #(
  parameter int ADDR_W    = 32,
  parameter int MAX_BURST = 16
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [23:0]       nwords_i,
  output logic              busy_o,
  output logic              done_o,
  output logic              err_o,
  // Stream in
  input  logic [31:0]       s_tdata,
  input  logic              s_tvalid,
  output logic              s_tready,
  // AXI4 write master
  output logic [ADDR_W-1:0] m_axi_awaddr,
  output logic [7:0]        m_axi_awlen,
  output logic [2:0]        m_axi_awsize,
  output logic [1:0]        m_axi_awburst,
  output logic              m_axi_awvalid,
  input  logic              m_axi_awready,
  output logic [31:0]       m_axi_wdata,
  output logic [3:0]        m_axi_wstrb,
  output logic              m_axi_wlast,
  output logic              m_axi_wvalid,
  input  logic              m_axi_wready,
  input  logic [1:0]        m_axi_bresp,
  input  logic              m_axi_bvalid,
  output logic              m_axi_bready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  typedef enum logic [2:0] {S_IDLE, S_CALC, S_AW, S_W, S_B, S_DONE} state_t;
  state_t state;
  logic [ADDR_W-1:0] addr_q;
  logic [23:0]       left;
  logic [8:0]        blen, beat;
  wire  [10:0]       to_bound = 11'd1024 - {1'b0, addr_q[11:2]};
  wire  [23:0]       cap0 = (left < 24'(MAX_BURST)) ? left : 24'(MAX_BURST);
  wire  [23:0]       cap1 = (cap0 < 24'(to_bound)) ? cap0 : 24'(to_bound);

  assign busy_o        = (state != S_IDLE);
  assign m_axi_awaddr  = addr_q;
  assign m_axi_awlen   = 8'(blen - 9'd1);
  assign m_axi_awsize  = 3'b010;
  assign m_axi_awburst = 2'b01;
  assign m_axi_awvalid = (state == S_AW);
  assign m_axi_wdata   = s_tdata;
  assign m_axi_wstrb   = 4'hF;
  assign m_axi_wvalid  = (state == S_W) & s_tvalid;
  assign m_axi_wlast   = (beat == blen - 9'd1);
  assign s_tready      = (state == S_W) & m_axi_wready;
  assign m_axi_bready  = (state == S_B);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; addr_q <= '0; left <= '0; blen <= '0; beat <= '0;
      done_o <= 1'b0; err_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state)
        S_IDLE: if (start_i) begin
          addr_q <= addr_i; left <= nwords_i; err_o <= 1'b0;
          state <= (nwords_i == 24'd0) ? S_DONE : S_CALC;
        end
        S_CALC: begin blen <= 9'(cap1); beat <= '0; state <= S_AW; end
        S_AW: if (m_axi_awready) begin
          addr_q <= addr_q + ADDR_W'({blen, 2'b00});
          left   <= left - 24'(blen);
          state  <= S_W;
        end
        S_W: if (m_axi_wvalid & m_axi_wready) begin
          beat <= beat + 9'd1;
          if (m_axi_wlast) state <= S_B;
        end
        S_B: if (m_axi_bvalid) begin
          if (m_axi_bresp != 2'b00) err_o <= 1'b1;
          state <= (left == 24'd0) ? S_DONE : S_CALC;
        end
        S_DONE: begin done_o <= 1'b1; state <= S_IDLE; end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
