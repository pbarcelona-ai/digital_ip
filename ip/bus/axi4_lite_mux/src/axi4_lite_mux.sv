// ***************
// Filename: axi4_lite_mux.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite 1-to-N interconnect (address decoded mux).
//   Version 1.0.0. One AXI-Lite slave port is routed to NSLAVE master
//   ports selected by axi4_lite_decoder (BASE/MASK regions). Addresses are
//   passed through unchanged. One write and one read may be outstanding at
//   a time (reads and writes are independent). Accesses that hit no region
//   are answered directly with DECERR (bresp/rresp = 2'b11, read data 0)
//   and never reach a slave. Master-port signals are packed vectors (slave
//   i uses slice i). Clock - aclk. Reset - synchronous aresetn, idle.
//   Latency - 1 clock for write/read address acceptance plus 1 clock for
//   the response beat on top of the slave latency. Timing - decoder output
//   is registered before use. Errors - DECERR for unmapped addresses; an
//   ill-formed region map is rejected by the decoder at elaboration.
// Date: 2026-09-29
module axi4_lite_mux #(
  parameter int ADDR_W = 32,
  parameter int NSLAVE = 4,
  parameter logic [NSLAVE*ADDR_W-1:0] BASE = {32'h0000_3000, 32'h0000_2000, 32'h0000_1000, 32'h0000_0000},
  parameter logic [NSLAVE*ADDR_W-1:0] MASK = {4{32'hFFFF_F000}}
) (
  input  logic                       aclk,
  input  logic                       aresetn,
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
  output logic [NSLAVE*ADDR_W-1:0]   m_axil_awaddr,
  output logic [NSLAVE-1:0]          m_axil_awvalid,
  input  logic [NSLAVE-1:0]          m_axil_awready,
  output logic [NSLAVE*32-1:0]       m_axil_wdata,
  output logic [NSLAVE*4-1:0]        m_axil_wstrb,
  output logic [NSLAVE-1:0]          m_axil_wvalid,
  input  logic [NSLAVE-1:0]          m_axil_wready,
  input  logic [NSLAVE*2-1:0]        m_axil_bresp,
  input  logic [NSLAVE-1:0]          m_axil_bvalid,
  output logic [NSLAVE-1:0]          m_axil_bready,
  output logic [NSLAVE*ADDR_W-1:0]   m_axil_araddr,
  output logic [NSLAVE-1:0]          m_axil_arvalid,
  input  logic [NSLAVE-1:0]          m_axil_arready,
  input  logic [NSLAVE*32-1:0]       m_axil_rdata,
  input  logic [NSLAVE*2-1:0]        m_axil_rresp,
  input  logic [NSLAVE-1:0]          m_axil_rvalid,
  output logic [NSLAVE-1:0]          m_axil_rready
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int SW = (NSLAVE > 1) ? $clog2(NSLAVE) : 1;
  // ---------------- write path ----------------
  typedef enum logic [2:0] {W_IDLE, W_ISSUE, W_RESP, W_ERR, W_DONE} wst_t;
  wst_t wst;
  logic aw_got, w_got;
  logic [ADDR_W-1:0] aw_q;
  logic [31:0] w_q;
  logic [3:0] ws_q;
  logic [NSLAVE-1:0] wsel;
  logic wmiss, wmulti;
  logic aw_done, w_done;
  logic [1:0] bresp_q;
  axi4_lite_decoder #(.ADDR_W(ADDR_W), .NSLAVE(NSLAVE), .BASE(BASE), .MASK(MASK)) u_wdec (
    .addr_i(aw_q),
    .sel_o(wsel),
    .miss_o(wmiss),
    .multi_o(wmulti)
  );
  assign s_axil_awready = (wst == W_IDLE) & ~aw_got;
  assign s_axil_wready  = (wst == W_IDLE) & ~w_got;
  always_comb begin
    m_axil_awaddr = '0;
    m_axil_wdata = '0;
    m_axil_wstrb = '0;
    m_axil_awvalid = '0;
    m_axil_wvalid = '0;
    m_axil_bready = '0;
    for (int i = 0; i < NSLAVE; i++) begin
      m_axil_awaddr[i*ADDR_W +: ADDR_W] = aw_q;
      m_axil_wdata[i*32 +: 32] = w_q;
      m_axil_wstrb[i*4 +: 4] = ws_q;
      m_axil_awvalid[i] = (wst == W_ISSUE) & wsel[i] & ~aw_done;
      m_axil_wvalid[i]  = (wst == W_ISSUE) & wsel[i] & ~w_done;
      m_axil_bready[i]  = (wst == W_RESP) & wsel[i] & (s_axil_bvalid ? s_axil_bready : 1'b1) & ~s_axil_bvalid;
    end
  end
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wst <= W_IDLE;
      aw_got <= 1'b0;
      w_got <= 1'b0;
      aw_done <= 1'b0;
      w_done <= 1'b0;
      s_axil_bvalid <= 1'b0;
      s_axil_bresp <= '0;
      aw_q <= '0;
      w_q <= '0;
      ws_q <= '0;
    end else begin
      case (wst)
        W_IDLE: begin
          if (s_axil_awvalid & s_axil_awready) begin
            aw_got <= 1'b1;
            aw_q <= s_axil_awaddr;
          end
          if (s_axil_wvalid & s_axil_wready) begin
            w_got <= 1'b1;
            w_q <= s_axil_wdata;
            ws_q <= s_axil_wstrb;
          end
          if ((aw_got | (s_axil_awvalid & s_axil_awready)) & (w_got | (s_axil_wvalid & s_axil_wready))) begin
            wst <= W_ISSUE;
            aw_done <= 1'b0;
            w_done <= 1'b0;
          end
        end
        W_ISSUE: begin
          if (wmiss) begin
            s_axil_bvalid <= 1'b1;
            s_axil_bresp <= 2'b11;
            wst <= W_DONE;
          end
          else begin
            if (|(m_axil_awvalid & m_axil_awready)) aw_done <= 1'b1;
            if (|(m_axil_wvalid & m_axil_wready)) w_done <= 1'b1;
            if ((aw_done | |(m_axil_awvalid & m_axil_awready)) & (w_done | |(m_axil_wvalid & m_axil_wready))) wst <= W_RESP;
          end
        end
        W_RESP: begin
          if (|(m_axil_bvalid & wsel)) begin
            s_axil_bvalid <= 1'b1;
            for (int i = 0; i < NSLAVE; i++) if (wsel[i]) s_axil_bresp <= m_axil_bresp[i*2 +: 2];
            wst <= W_DONE;
          end
        end
        W_DONE: if (s_axil_bvalid & s_axil_bready) begin
          s_axil_bvalid <= 1'b0;
          aw_got <= 1'b0;
          w_got <= 1'b0;
          wst <= W_IDLE;
        end
        default: wst <= W_IDLE;
      endcase
    end
  end
  // ---------------- read path ----------------
  typedef enum logic [2:0] {R_IDLE, R_DEC, R_ISSUE, R_RESP, R_DONE} rst_t;
  rst_t rst;
  logic [ADDR_W-1:0] ar_q;
  logic [NSLAVE-1:0] rsel;
  logic rmiss, rmulti;
  axi4_lite_decoder #(.ADDR_W(ADDR_W), .NSLAVE(NSLAVE), .BASE(BASE), .MASK(MASK)) u_rdec (
    .addr_i(ar_q),
    .sel_o(rsel),
    .miss_o(rmiss),
    .multi_o(rmulti)
  );
  assign s_axil_arready = (rst == R_IDLE);
  always_comb begin
    m_axil_araddr = '0;
    m_axil_arvalid = '0;
    m_axil_rready = '0;
    for (int i = 0; i < NSLAVE; i++) begin
      m_axil_araddr[i*ADDR_W +: ADDR_W] = ar_q;
      m_axil_arvalid[i] = (rst == R_ISSUE) & rsel[i];
      m_axil_rready[i]  = (rst == R_RESP) & rsel[i];
    end
  end
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rst <= R_IDLE;
      ar_q <= '0;
      s_axil_rvalid <= 1'b0;
      s_axil_rdata <= '0;
      s_axil_rresp <= '0;
    end
    else begin
      case (rst)
        R_IDLE: if (s_axil_arvalid) begin
          ar_q <= s_axil_araddr;
          rst <= R_DEC;
        end
        R_DEC: rst <= R_ISSUE;
        R_ISSUE: begin
          if (rmiss) begin
            s_axil_rvalid <= 1'b1;
            s_axil_rdata <= '0;
            s_axil_rresp <= 2'b11;
            rst <= R_DONE;
          end
          else if (|(m_axil_arvalid & m_axil_arready)) rst <= R_RESP;
        end
        R_RESP: if (|(m_axil_rvalid & rsel)) begin
          s_axil_rvalid <= 1'b1;
          for (int i = 0; i < NSLAVE; i++) if (rsel[i]) begin
            s_axil_rdata <= m_axil_rdata[i*32 +: 32];
            s_axil_rresp <= m_axil_rresp[i*2 +: 2];
          end
          rst <= R_DONE;
        end
        R_DONE: if (s_axil_rready) begin
          s_axil_rvalid <= 1'b0;
          rst <= R_IDLE;
        end
        default: rst <= R_IDLE;
      endcase
    end
  end
endmodule
