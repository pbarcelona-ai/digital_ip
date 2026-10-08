// ***************
// Filename: py_axil_xbar.sv
// Author: FPGA Cores 4 U
// Description: 1-to-NSLAVE AXI4-Lite interconnect for a single master with
//   one transaction outstanding per direction (py_core). Address decode
//   uses axi4_lite_decoder (region i matches (addr & MASK[i]) == BASE[i]).
//   The selected slave is latched when a request arrives and held until its
//   response handshake. Unmapped addresses are completed internally with
//   DECERR. Address, write data and strobes are broadcast to every slave;
//   valid/ready/response signals are per slave (bit i = slave i). Clock -
//   aclk only. Reset - synchronous aresetn (active low). Latency - one
//   clock added to the address phase for decode.
// Date: 2026-10-01
module py_axil_xbar #(
  parameter int NSLAVE = 4,
  parameter logic [NSLAVE*32-1:0] BASE = '0,
  parameter logic [NSLAVE*32-1:0] MASK = '0
) (
  input  logic                 aclk,
  input  logic                 aresetn,
  // Master port (from the processor)
  input  logic [31:0]          s_axil_awaddr,
  input  logic                 s_axil_awvalid,
  output logic                 s_axil_awready,
  input  logic [31:0]          s_axil_wdata,
  input  logic [3:0]           s_axil_wstrb,
  input  logic                 s_axil_wvalid,
  output logic                 s_axil_wready,
  output logic [1:0]           s_axil_bresp,
  output logic                 s_axil_bvalid,
  input  logic                 s_axil_bready,
  input  logic [31:0]          s_axil_araddr,
  input  logic                 s_axil_arvalid,
  output logic                 s_axil_arready,
  output logic [31:0]          s_axil_rdata,
  output logic [1:0]           s_axil_rresp,
  output logic                 s_axil_rvalid,
  input  logic                 s_axil_rready,
  // Slave ports (broadcast address/data, per-slave handshakes)
  output logic [31:0]          m_axil_awaddr,
  output logic [NSLAVE-1:0]    m_axil_awvalid,
  input  logic [NSLAVE-1:0]    m_axil_awready,
  output logic [31:0]          m_axil_wdata,
  output logic [3:0]           m_axil_wstrb,
  output logic [NSLAVE-1:0]    m_axil_wvalid,
  input  logic [NSLAVE-1:0]    m_axil_wready,
  input  logic [NSLAVE*2-1:0]  m_axil_bresp,
  input  logic [NSLAVE-1:0]    m_axil_bvalid,
  output logic [NSLAVE-1:0]    m_axil_bready,
  output logic [31:0]          m_axil_araddr,
  output logic [NSLAVE-1:0]    m_axil_arvalid,
  input  logic [NSLAVE-1:0]    m_axil_arready,
  input  logic [NSLAVE*32-1:0] m_axil_rdata,
  input  logic [NSLAVE*2-1:0]  m_axil_rresp,
  input  logic [NSLAVE-1:0]    m_axil_rvalid,
  output logic [NSLAVE-1:0]    m_axil_rready
);
  logic [NSLAVE-1:0] aw_hit, ar_hit; logic aw_miss, ar_miss, aw_multi, ar_multi;
  axi4_lite_decoder #(.ADDR_W(32), .NSLAVE(NSLAVE), .BASE(BASE), .MASK(MASK)) u_dec_aw (
    .addr_i(s_axil_awaddr), .sel_o(aw_hit), .miss_o(aw_miss), .multi_o(aw_multi));
  axi4_lite_decoder #(.ADDR_W(32), .NSLAVE(NSLAVE), .BASE(BASE), .MASK(MASK)) u_dec_ar (
    .addr_i(s_axil_araddr), .sel_o(ar_hit), .miss_o(ar_miss), .multi_o(ar_multi));

  assign m_axil_awaddr = s_axil_awaddr; assign m_axil_wdata = s_axil_wdata; assign m_axil_wstrb = s_axil_wstrb;
  assign m_axil_araddr = s_axil_araddr;

  // ---------------- write ----------------
  typedef enum logic [1:0] {W_IDLE, W_FWD, W_ERR, W_ERR_B} wst_e;
  wst_e wst; logic [NSLAVE-1:0] wsel; logic err_aw, err_w;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin wst <= W_IDLE; wsel <= '0; err_aw <= 1'b0; err_w <= 1'b0; end
    else case (wst)
      W_IDLE: if (s_axil_awvalid) begin
        wsel <= aw_hit; err_aw <= 1'b0; err_w <= 1'b0;
        if (aw_miss) wst <= W_ERR; else wst <= W_FWD;
      end
      W_FWD:  if (s_axil_bvalid && s_axil_bready) wst <= W_IDLE;
      W_ERR: begin                                   // swallow AW and W, then DECERR
        if (s_axil_awvalid) err_aw <= 1'b1;
        if (s_axil_wvalid)  err_w  <= 1'b1;
        if ((err_aw || s_axil_awvalid) && (err_w || s_axil_wvalid)) wst <= W_ERR_B;
      end
      W_ERR_B: if (s_axil_bready) wst <= W_IDLE;
      default: wst <= W_IDLE;
    endcase
  end
  wire w_fwd = (wst == W_FWD);
  assign m_axil_awvalid = w_fwd ? wsel & {NSLAVE{s_axil_awvalid}} : '0;
  assign m_axil_wvalid  = w_fwd ? wsel & {NSLAVE{s_axil_wvalid}}  : '0;
  assign m_axil_bready  = w_fwd ? wsel & {NSLAVE{s_axil_bready}}  : '0;
  always_comb begin
    s_axil_awready = (wst == W_ERR) && !err_aw;
    s_axil_wready  = (wst == W_ERR) && !err_w;
    s_axil_bvalid  = (wst == W_ERR_B);
    s_axil_bresp   = (wst == W_ERR_B) ? 2'b11 : 2'b00;
    for (int i = 0; i < NSLAVE; i++) if (w_fwd && wsel[i]) begin
      s_axil_awready = m_axil_awready[i]; s_axil_wready = m_axil_wready[i];
      s_axil_bvalid  = m_axil_bvalid[i];  s_axil_bresp  = m_axil_bresp[i*2 +: 2];
    end
  end

  // ---------------- read ----------------
  typedef enum logic [1:0] {R_IDLE, R_FWD, R_ERR} rst_e;
  rst_e rst; logic [NSLAVE-1:0] rsel;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin rst <= R_IDLE; rsel <= '0; end
    else case (rst)
      R_IDLE: if (s_axil_arvalid) begin rsel <= ar_hit; if (ar_miss) rst <= R_ERR; else rst <= R_FWD; end
      R_FWD:  if (s_axil_rvalid && s_axil_rready) rst <= R_IDLE;
      R_ERR:  if (s_axil_rvalid && s_axil_rready) rst <= R_IDLE;
      default: rst <= R_IDLE;
    endcase
  end
  // DECERR read: accept AR in R_ERR, then present rvalid until rready
  logic r_err_ar;
  always_ff @(posedge aclk) begin
    if (!aresetn || rst != R_ERR) r_err_ar <= 1'b0;
    else if (s_axil_arvalid) r_err_ar <= 1'b1;
  end
  wire r_fwd = (rst == R_FWD);
  assign m_axil_arvalid = r_fwd ? rsel & {NSLAVE{s_axil_arvalid}} : '0;
  assign m_axil_rready  = r_fwd ? rsel & {NSLAVE{s_axil_rready}}  : '0;
  always_comb begin
    s_axil_arready = (rst == R_ERR) && !r_err_ar;
    s_axil_rvalid  = (rst == R_ERR) && r_err_ar;
    s_axil_rresp   = s_axil_rvalid ? 2'b11 : 2'b00;
    s_axil_rdata   = '0;
    for (int i = 0; i < NSLAVE; i++) if (r_fwd && rsel[i]) begin
      s_axil_arready = m_axil_arready[i]; s_axil_rvalid = m_axil_rvalid[i];
      s_axil_rresp   = m_axil_rresp[i*2 +: 2]; s_axil_rdata = m_axil_rdata[i*32 +: 32];
    end
  end
endmodule
