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
  // s_axil: axil_if.slave (ip/shared/src/interfaces/axil_if.sv), ADDR_W = 32
  axil_if.slave s_axil,
  // Slave ports (broadcast address/data, per-slave handshakes)
  // m_axil: NSLAVE x axil_if.master (ip/shared/src/interfaces/axil_if.sv), packed: slave k in [k],
  // [k*2 +: 2], [k*32 +: 32]; address / write data broadcast. Kept discrete: an array of
  // interfaces cannot be driven member-wise in Icarus 14 (the parent builds one axil_if per slave)
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
  logic [NSLAVE-1:0] aw_hit, ar_hit;
  logic aw_miss, ar_miss, aw_multi, ar_multi;
  axi4_lite_decoder #(
    .ADDR_W(32),
    .NSLAVE(NSLAVE),
    .BASE(BASE),
    .MASK(MASK)
  ) u_dec_aw (
    .addr_i(s_axil.awaddr),
    .sel_o(aw_hit),
    .miss_o(aw_miss),
    .multi_o(aw_multi)
  );
  axi4_lite_decoder #(
    .ADDR_W(32),
    .NSLAVE(NSLAVE),
    .BASE(BASE),
    .MASK(MASK)
  ) u_dec_ar (
    .addr_i(s_axil.araddr),
    .sel_o(ar_hit),
    .miss_o(ar_miss),
    .multi_o(ar_multi)
  );

  // overlapping regions are rejected at elaboration (axi4_lite_decoder), so multi_o stays low
  wire unused_ok = &{1'b0, aw_multi, ar_multi, 1'b0};

  assign m_axil_awaddr = s_axil.awaddr;
  assign m_axil_wdata = s_axil.wdata;
  assign m_axil_wstrb = s_axil.wstrb;
  assign m_axil_araddr = s_axil.araddr;

  // ---------------- write ----------------
  typedef enum logic [1:0] {W_IDLE, W_FWD, W_ERR, W_ERR_B} wst_e;
  wst_e wst;
  logic [NSLAVE-1:0] wsel;
  logic err_aw, err_w;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      wst <= W_IDLE;
      wsel <= '0;
      err_aw <= 1'b0;
      err_w <= 1'b0;
    end
    else case (wst)
      W_IDLE: if (s_axil.awvalid) begin
        wsel <= aw_hit;
        err_aw <= 1'b0;
        err_w <= 1'b0;
        if (aw_miss) wst <= W_ERR;
        else wst <= W_FWD;
      end
      W_FWD:  if (s_axil.bvalid && s_axil.bready) wst <= W_IDLE;
      W_ERR: begin                                   // swallow AW and W, then DECERR
        if (s_axil.awvalid) err_aw <= 1'b1;
        if (s_axil.wvalid)  err_w  <= 1'b1;
        if ((err_aw || s_axil.awvalid) && (err_w || s_axil.wvalid)) wst <= W_ERR_B;
      end
      W_ERR_B: if (s_axil.bready) wst <= W_IDLE;
      default: wst <= W_IDLE;
    endcase
  end
  wire w_fwd = (wst == W_FWD);
  assign m_axil_awvalid = w_fwd ? wsel & {NSLAVE{s_axil.awvalid}} : '0;
  assign m_axil_wvalid  = w_fwd ? wsel & {NSLAVE{s_axil.wvalid}}  : '0;
  assign m_axil_bready  = w_fwd ? wsel & {NSLAVE{s_axil.bready}}  : '0;
  always_comb begin
    s_axil.awready = (wst == W_ERR) && !err_aw;
    s_axil.wready  = (wst == W_ERR) && !err_w;
    s_axil.bvalid  = (wst == W_ERR_B);
    s_axil.bresp   = (wst == W_ERR_B) ? 2'b11 : 2'b00;
    for (int i = 0; i < NSLAVE; i++) if (w_fwd && wsel[i]) begin
      s_axil.awready = m_axil_awready[i];
      s_axil.wready = m_axil_wready[i];
      s_axil.bvalid  = m_axil_bvalid[i];
      s_axil.bresp  = m_axil_bresp[i*2 +: 2];
    end
  end

  // ---------------- read ----------------
  typedef enum logic [1:0] {R_IDLE, R_FWD, R_ERR} rst_e;
  rst_e rst;
  logic [NSLAVE-1:0] rsel;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      rst <= R_IDLE;
      rsel <= '0;
    end
    else case (rst)
      R_IDLE: if (s_axil.arvalid) begin
        rsel <= ar_hit;
        if (ar_miss) rst <= R_ERR;
        else rst <= R_FWD;
      end
      R_FWD:  if (s_axil.rvalid && s_axil.rready) rst <= R_IDLE;
      R_ERR:  if (s_axil.rvalid && s_axil.rready) rst <= R_IDLE;
      default: rst <= R_IDLE;
    endcase
  end
  // DECERR read: accept AR in R_ERR, then present rvalid until rready
  logic r_err_ar;
  always_ff @(posedge aclk) begin
    if (!aresetn || rst != R_ERR) r_err_ar <= 1'b0;
    else if (s_axil.arvalid) r_err_ar <= 1'b1;
  end
  wire r_fwd = (rst == R_FWD);
  assign m_axil_arvalid = r_fwd ? rsel & {NSLAVE{s_axil.arvalid}} : '0;
  assign m_axil_rready  = r_fwd ? rsel & {NSLAVE{s_axil.rready}}  : '0;
  always_comb begin
    s_axil.arready = (rst == R_ERR) && !r_err_ar;
    s_axil.rvalid  = (rst == R_ERR) && r_err_ar;
    s_axil.rresp   = s_axil.rvalid ? 2'b11 : 2'b00;
    s_axil.rdata   = '0;
    for (int i = 0; i < NSLAVE; i++) if (r_fwd && rsel[i]) begin
      s_axil.arready = m_axil_arready[i];
      s_axil.rvalid = m_axil_rvalid[i];
      s_axil.rresp   = m_axil_rresp[i*2 +: 2];
      s_axil.rdata = m_axil_rdata[i*32 +: 32];
    end
  end
endmodule
