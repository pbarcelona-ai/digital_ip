// ***************
// Filename: dma_rd_engine.sv
// Author: FPGA Cores 4 U
// Description: AXI4 read burst engine for the DMA IPs. Reads NWORDS 32-bit
//   words starting at a word-aligned address using INCR bursts of up to
//   MAX_BURST beats that never cross a 4 KB boundary, and streams the data
//   out on an AXI-Stream master (tlast on the final word). Reports busy, a
//   done pulse and a sticky error flag when any read response is not OKAY.
//   Version 1.0.0. Helper block of its IP; see the top level description for
//   clock, reset, latency and error behavior. Clock - the clock of the parent
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
//   block, all signals are synchronous to it. Reset - synchronous, driven by
//   the parent block. Latency - as documented in the parent block, fixed and
//   independent of data. Errors - none reported here, out-of-range parameters
//   stop elaboration or are handled by the parent block.
// Date: 2026-09-29
module dma_rd_engine #(
  parameter int ADDR_W    = 32,
  parameter int MAX_BURST = 16          // beats per burst (<= 256)
) (
  input  logic              clk,
  input  logic              rst_n,
  input  logic              start_i,    // pulse, accepted when idle
  input  logic [ADDR_W-1:0] addr_i,
  input  logic [23:0]       nwords_i,
  output logic              busy_o,
  output logic              done_o,     // one clock
  output logic              err_o,      // sticky until next start
  // AXI4 read master
  output logic [ADDR_W-1:0] m_axi_araddr,
  output logic [7:0]        m_axi_arlen,
  output logic [2:0]        m_axi_arsize,
  output logic [1:0]        m_axi_arburst,
  output logic              m_axi_arvalid,
  input  logic              m_axi_arready,
  input  logic [31:0]       m_axi_rdata,
  input  logic [1:0]        m_axi_rresp,
  input  logic              m_axi_rlast,
  input  logic              m_axi_rvalid,
  output logic              m_axi_rready,
  // Stream out
  output logic [31:0]       m_tdata,
  output logic              m_tvalid,
  input  logic              m_tready,
  output logic              m_tlast
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;

  typedef enum logic [2:0] {S_IDLE, S_CALC, S_AR, S_DATA, S_DONE} state_t;
  state_t state;
  logic [ADDR_W-1:0] addr_q;
  logic [23:0]       left;
  logic [8:0]        blen;             // words in the current burst (1..256)
  wire  [10:0]       to_bound = 11'd1024 - {1'b0, addr_q[11:2]};   // words to 4 KB edge
  wire  [23:0]       cap0 = (left < 24'(MAX_BURST)) ? left : 24'(MAX_BURST);
  wire  [23:0]       cap1 = (cap0 < 24'(to_bound)) ? cap0 : 24'(to_bound);

  assign busy_o        = (state != S_IDLE);
  assign m_axi_araddr  = addr_q;
  assign m_axi_arlen   = 8'(blen - 9'd1);
  assign m_axi_arsize  = 3'b010;       // 4 bytes
  assign m_axi_arburst = 2'b01;        // INCR
  assign m_axi_arvalid = (state == S_AR);
  assign m_axi_rready  = (state == S_DATA) & m_tready;
  assign m_tvalid      = (state == S_DATA) & m_axi_rvalid;
  assign m_tdata       = m_axi_rdata;
  assign m_tlast       = m_axi_rlast & (left == 24'd0);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE; addr_q <= '0; left <= '0; blen <= '0; done_o <= 1'b0; err_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      case (state)
        S_IDLE: if (start_i) begin
          addr_q <= addr_i; left <= nwords_i; err_o <= 1'b0;
          state <= state_t'((nwords_i == 24'd0) ? S_DONE : S_CALC);
        end
        S_CALC: begin blen <= 9'(cap1); state <= S_AR; end
        S_AR: if (m_axi_arready) begin
          addr_q <= addr_q + ADDR_W'({blen, 2'b00});
          left   <= left - 24'(blen);
          state  <= S_DATA;
        end
        S_DATA: if (m_axi_rvalid & m_tready) begin
          if (m_axi_rresp != 2'b00) err_o <= 1'b1;
          if (m_axi_rlast) state <= state_t'((left == 24'd0) ? S_DONE : S_CALC);
        end
        S_DONE: begin done_o <= 1'b1; state <= S_IDLE; end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule
