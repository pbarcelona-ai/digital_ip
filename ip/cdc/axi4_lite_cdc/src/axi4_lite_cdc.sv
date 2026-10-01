// ***************
// Filename: axi4_lite_cdc.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite clock domain bridge. An AXI-Lite slave in the source
//   clock domain is connected to an AXI-Lite master in the destination domain
//   using a toggle request / toggle acknowledge handshake with two flop
//   synchronizers. One transaction is outstanding at a time; address, data
//   and response buses are held stable while the handshake crosses, so no
//   per-bit synchronization is needed. Works for any clock ratio. Version
//   1.0.0. Clocks - s_clk (slave side) and m_clk (master side) unrelated,
//   each channel crosses with a toggle handshake and two-flop synchronizers.
//   Reset - synchronous active low per domain, reset both together. Latency -
//   roughly 6 to 10 clocks of the slower domain per transaction; one
//   transaction outstanding at a time. Timing - address/data registers cross
//   under a max-delay constraint of one destination period. Errors - the
//   master side response (including SLVERR) is passed back unchanged; illegal
//   parameters stop elaboration. Clock - the clock of the parent block, all
//   signals are synchronous to it.
//   signals are synchronous to it.
// Date: 2026-09-29
module axi4_lite_cdc #(
  parameter int ADDR_W = 8
) (
  // Source domain: AXI-Lite slave
  input  logic              s_clk,
  input  logic              s_rst_n,
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // Destination domain: AXI-Lite master
  input  logic              m_clk,
  input  logic              m_rst_n,
  output logic [ADDR_W-1:0] m_axil_awaddr,
  output logic              m_axil_awvalid,
  input  logic              m_axil_awready,
  output logic [31:0]       m_axil_wdata,
  output logic [3:0]        m_axil_wstrb,
  output logic              m_axil_wvalid,
  input  logic              m_axil_wready,
  input  logic [1:0]        m_axil_bresp,
  input  logic              m_axil_bvalid,
  output logic              m_axil_bready,
  output logic [ADDR_W-1:0] m_axil_araddr,
  output logic              m_axil_arvalid,
  input  logic              m_axil_arready,
  input  logic [31:0]       m_axil_rdata,
  input  logic [1:0]        m_axil_rresp,
  input  logic              m_axil_rvalid,
  output logic              m_axil_rready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (ADDR_W < 2 || ADDR_W > 32) begin : g_chk_aw $error("%m: ADDR_W must be 2..32"); end

  // ---------------- source domain ----------------
  typedef enum logic [2:0] {S_IDLE, S_WAIT, S_BRESP, S_RRESP} s_state_t;
  s_state_t ss;
  logic aw_seen, w_seen;
  logic [ADDR_W-1:0] req_addr; logic [31:0] req_wdata; logic [3:0] req_wstrb;
  logic req_is_wr, req_tog;
  logic [31:0] rsp_rdata; logic [1:0] rsp_resp;    // driven by dest domain
  logic ack_tog_sync, ack_prev;

  assign s_axil_awready = (ss == S_IDLE) & ~aw_seen;
  assign s_axil_wready  = (ss == S_IDLE) & ~w_seen;
  assign s_axil_arready = (ss == S_IDLE) & ~aw_seen & ~w_seen;

  cdc_sync_bit u_ack_sync (.clk(s_clk), .d_i(ack_tog), .q_o(ack_tog_sync));

  always_ff @(posedge s_clk) begin
    if (!s_rst_n) begin
      ss <= S_IDLE; aw_seen <= 1'b0; w_seen <= 1'b0; req_tog <= 1'b0; ack_prev <= 1'b0;
      s_axil_bvalid <= 1'b0; s_axil_rvalid <= 1'b0; req_is_wr <= 1'b0;
      req_addr <= '0; req_wdata <= '0; req_wstrb <= '0; s_axil_bresp <= '0;
      s_axil_rdata <= '0; s_axil_rresp <= '0;
    end else begin
      case (ss)
        S_IDLE: begin
          if (s_axil_awvalid & s_axil_awready) begin aw_seen <= 1'b1; req_addr <= s_axil_awaddr; end
          if (s_axil_wvalid & s_axil_wready) begin
            w_seen <= 1'b1; req_wdata <= s_axil_wdata; req_wstrb <= s_axil_wstrb; end
          if ((aw_seen | (s_axil_awvalid & s_axil_awready)) &
              (w_seen  | (s_axil_wvalid  & s_axil_wready ))) begin
            // Wait one cycle so request registers are settled, then toggle
            ss <= S_WAIT; req_is_wr <= 1'b1;
          end else if (s_axil_arvalid & s_axil_arready) begin
            req_addr <= s_axil_araddr; req_is_wr <= 1'b0; ss <= S_WAIT;
          end
        end
        S_WAIT: begin
          if (req_tog == ack_prev) begin req_tog <= ~req_tog; end   // launch request
          else if (ack_tog_sync != ack_prev) begin                  // acknowledged
            ack_prev <= ack_tog_sync; aw_seen <= 1'b0; w_seen <= 1'b0;
            if (req_is_wr) begin s_axil_bvalid <= 1'b1; s_axil_bresp <= rsp_resp; ss <= S_BRESP; end
            else begin s_axil_rvalid <= 1'b1; s_axil_rdata <= rsp_rdata; s_axil_rresp <= rsp_resp; ss <= S_RRESP; end
          end
        end
        S_BRESP: if (s_axil_bready) begin s_axil_bvalid <= 1'b0; ss <= S_IDLE; end
        S_RRESP: if (s_axil_rready) begin s_axil_rvalid <= 1'b0; ss <= S_IDLE; end
        default: ss <= S_IDLE;
      endcase
    end
  end

  // ---------------- destination domain ----------------
  typedef enum logic [2:0] {D_IDLE, D_WR, D_WRESP, D_RD, D_RRESP, D_ACK} d_state_t;
  d_state_t ds;
  logic req_tog_sync, req_prev, ack_tog;
  logic aw_done, w_done;
  cdc_sync_bit u_req_sync (.clk(m_clk), .d_i(req_tog), .q_o(req_tog_sync));

  assign m_axil_awaddr  = req_addr;
  assign m_axil_araddr  = req_addr;
  assign m_axil_wdata   = req_wdata;
  assign m_axil_wstrb   = req_wstrb;
  assign m_axil_awvalid = (ds == D_WR) & ~aw_done;
  assign m_axil_wvalid  = (ds == D_WR) & ~w_done;
  assign m_axil_bready  = (ds == D_WRESP);
  assign m_axil_arvalid = (ds == D_RD);
  assign m_axil_rready  = (ds == D_RRESP);

  always_ff @(posedge m_clk) begin
    if (!m_rst_n) begin
      ds <= D_IDLE; req_prev <= 1'b0; ack_tog <= 1'b0; aw_done <= 1'b0; w_done <= 1'b0;
      rsp_rdata <= '0; rsp_resp <= '0;
    end else begin
      case (ds)
        D_IDLE: if (req_tog_sync != req_prev) begin
          req_prev <= req_tog_sync; aw_done <= 1'b0; w_done <= 1'b0;
          ds <= req_is_wr ? D_WR : D_RD;
        end
        D_WR: begin
          if (m_axil_awvalid & m_axil_awready) aw_done <= 1'b1;
          if (m_axil_wvalid & m_axil_wready) w_done <= 1'b1;
          if ((aw_done | (m_axil_awvalid & m_axil_awready)) & (w_done | (m_axil_wvalid & m_axil_wready)))
            ds <= D_WRESP;
        end
        D_WRESP: if (m_axil_bvalid) begin rsp_resp <= m_axil_bresp; ds <= D_ACK; end
        D_RD: if (m_axil_arready) ds <= D_RRESP;
        D_RRESP: if (m_axil_rvalid) begin rsp_rdata <= m_axil_rdata; rsp_resp <= m_axil_rresp; ds <= D_ACK; end
        D_ACK: begin ack_tog <= ~ack_tog; ds <= D_IDLE; end
        default: ds <= D_IDLE;
      endcase
    end
  end
endmodule
