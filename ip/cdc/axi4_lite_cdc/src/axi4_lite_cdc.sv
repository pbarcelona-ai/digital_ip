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
//   A write (AW or W) presented in the same clock as a read goes first; the
//   read waits. Reset - synchronous active low per domain; assert both
//   together and hold each for at least 3 clocks of its domain with the other
//   domain's clock running (the toggle synchronisers have no reset and must
//   flush). Latency -
//   roughly 6 to 10 clocks of the slower domain per transaction; one
//   transaction outstanding at a time. Timing - address/data registers cross
//   under a max-delay constraint of one destination period. Errors - the
//   master side response (including SLVERR) is passed back unchanged; illegal
//   parameters stop elaboration.
// Date: 2026-10-16
module axi4_lite_cdc #(
  parameter int ADDR_W = 8
) (
  // Source domain: AXI-Lite slave
  input  logic              s_clk,
  input  logic              s_rst_n,
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.slave s_axil,
  // Destination domain: AXI-Lite master
  input  logic              m_clk,
  input  logic              m_rst_n,
  // m_axil: axil_if.master (ip/shared/src/interfaces/axil_if.sv), ADDR_W = ADDR_W
  axil_if.master m_axil
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (ADDR_W < 2 || ADDR_W > 32) begin : g_chk_aw $error("%m: ADDR_W must be 2..32"); end

  // ---------------- source domain ----------------
  typedef enum logic [2:0] {S_IDLE, S_WAIT, S_BRESP, S_RRESP} s_state_t;
  s_state_t ss;
  logic aw_seen, w_seen;
  logic [ADDR_W-1:0] req_addr;
  logic [31:0] req_wdata;
  logic [3:0] req_wstrb;
  logic req_is_wr, req_tog;
  logic [31:0] rsp_rdata; // driven by dest domain
  logic [1:0] rsp_resp;
  logic ack_tog_sync, ack_prev;
  logic ack_tog;                       // driven by the destination side below

  assign s_axil.awready = (ss == S_IDLE) & ~aw_seen;
  assign s_axil.wready  = (ss == S_IDLE) & ~w_seen;
  assign s_axil.arready = (ss == S_IDLE) & ~aw_seen & ~w_seen & ~s_axil.awvalid & ~s_axil.wvalid;   // a write wins

  cdc_sync_bit u_ack_sync (
    .clk(s_clk),
    .d_i(ack_tog),
    .q_o(ack_tog_sync)
  );

  always_ff @(posedge s_clk) begin
    if (!s_rst_n) begin
      ss <= S_IDLE;
      aw_seen <= 1'b0;
      w_seen <= 1'b0;
      req_tog <= 1'b0;
      ack_prev <= 1'b0;
      s_axil.bvalid <= 1'b0;
      s_axil.rvalid <= 1'b0;
      req_is_wr <= 1'b0;
      req_addr <= '0;
      req_wdata <= '0;
      req_wstrb <= '0;
      s_axil.bresp <= '0;
      s_axil.rdata <= '0;
      s_axil.rresp <= '0;
    end else begin
      case (ss)
        S_IDLE: begin
          if (s_axil.awvalid & s_axil.awready) begin
            aw_seen <= 1'b1;
            req_addr <= s_axil.awaddr;
          end
          if (s_axil.wvalid & s_axil.wready) begin
            w_seen <= 1'b1;
            req_wdata <= s_axil.wdata;
            req_wstrb <= s_axil.wstrb;
            end
          if ((aw_seen | (s_axil.awvalid & s_axil.awready)) &
              (w_seen  | (s_axil.wvalid  & s_axil.wready ))) begin
            // Wait one cycle so request registers are settled, then toggle
            ss <= S_WAIT;
            req_is_wr <= 1'b1;
          end else if (s_axil.arvalid & s_axil.arready) begin
            req_addr <= s_axil.araddr;
            req_is_wr <= 1'b0;
            ss <= S_WAIT;
          end
        end
        S_WAIT: begin
          if (req_tog == ack_prev) begin req_tog <= ~req_tog; end   // launch request
          else if (ack_tog_sync != ack_prev) begin                  // acknowledged
            ack_prev <= ack_tog_sync;
            aw_seen <= 1'b0;
            w_seen <= 1'b0;
            if (req_is_wr) begin
              s_axil.bvalid <= 1'b1;
              s_axil.bresp <= rsp_resp;
              ss <= S_BRESP;
            end
            else begin
              s_axil.rvalid <= 1'b1;
              s_axil.rdata <= rsp_rdata;
              s_axil.rresp <= rsp_resp;
              ss <= S_RRESP;
            end
          end
        end
        S_BRESP: if (s_axil.bready) begin
          s_axil.bvalid <= 1'b0;
          ss <= S_IDLE;
        end
        S_RRESP: if (s_axil.rready) begin
          s_axil.rvalid <= 1'b0;
          ss <= S_IDLE;
        end
        default: ss <= S_IDLE;
      endcase
    end
  end

  // ---------------- destination domain ----------------
  typedef enum logic [2:0] {D_IDLE, D_WR, D_WRESP, D_RD, D_RRESP, D_ACK} d_state_t;
  d_state_t ds;
  logic req_tog_sync, req_prev;
  logic aw_done, w_done;
  cdc_sync_bit u_req_sync (
    .clk(m_clk),
    .d_i(req_tog),
    .q_o(req_tog_sync)
  );

  assign m_axil.awaddr  = req_addr;
  assign m_axil.araddr  = req_addr;
  assign m_axil.wdata   = req_wdata;
  assign m_axil.wstrb   = req_wstrb;
  assign m_axil.awvalid = (ds == D_WR) & ~aw_done;
  assign m_axil.wvalid  = (ds == D_WR) & ~w_done;
  assign m_axil.bready  = (ds == D_WRESP);
  assign m_axil.arvalid = (ds == D_RD);
  assign m_axil.rready  = (ds == D_RRESP);

  always_ff @(posedge m_clk) begin
    if (!m_rst_n) begin
      ds <= D_IDLE;
      req_prev <= 1'b0;
      ack_tog <= 1'b0;
      aw_done <= 1'b0;
      w_done <= 1'b0;
      rsp_rdata <= '0;
      rsp_resp <= '0;
    end else begin
      case (ds)
        D_IDLE: if (req_tog_sync != req_prev) begin
          req_prev <= req_tog_sync;
          aw_done <= 1'b0;
          w_done <= 1'b0;
          ds <= d_state_t'(req_is_wr ? D_WR : D_RD);
        end
        D_WR: begin
          if (m_axil.awvalid & m_axil.awready) aw_done <= 1'b1;
          if (m_axil.wvalid & m_axil.wready) w_done <= 1'b1;
          if ((aw_done | (m_axil.awvalid & m_axil.awready)) & (w_done | (m_axil.wvalid & m_axil.wready)))
            ds <= D_WRESP;
        end
        D_WRESP: if (m_axil.bvalid) begin
          rsp_resp <= m_axil.bresp;
          ds <= D_ACK;
        end
        D_RD: if (m_axil.arready) ds <= D_RRESP;
        D_RRESP: if (m_axil.rvalid) begin
          rsp_rdata <= m_axil.rdata;
          rsp_resp <= m_axil.rresp;
          ds <= D_ACK;
        end
        D_ACK: begin
          ack_tog <= ~ack_tog;
          ds <= D_IDLE;
        end
        default: ds <= D_IDLE;
      endcase
    end
  end
endmodule
