// ***************
// Filename: dma_engine.sv
// Author: FPGA Cores 4 U
// Description: Memory to memory DMA engine. Copies LEN bytes from SRC to DST
//   over one AXI4 master port using burst read and write engines decoupled by
//   a stream FIFO (bursts limited to MAX_BURST beats and never crossing 4
//   KB). Programmed over AXI-Lite - 0x00 CTRL [0]start (pulse) [1]irq_en,
//   0x04 SRC, 0x08 DST, 0x0C LEN (bytes, multiple of 4), 0x10 STATUS [0]busy
//   [8]done (W1C) [9]error (W1C). irq_o follows done when enabled. Addresses
//   must be 4 byte aligned. Version 1.0.0. Clock - single clock aclk, every
//   input is synchronous to it unless a two-flop synchronizer is mentioned.
//   Reset - synchronous active low aresetn, registers take the documented
//   reset values. Latency - AXI-Lite write response and read data follow the
//   request by about 2 to 3 clocks (ip_axil_regs, registered read path).
//   Timing - registered outputs, no combinational path from the bus to the
//   pins. Errors - out of range AXI-Lite accesses return SLVERR; illegal
//   parameter values stop elaboration with an $error. The AXI4 master follows
//   the AXI4 rules of 4 KB burst boundaries; a bus error response stops the
//   transfer and is reported in STATUS.
// Date: 2026-09-29
module dma_engine #(
  parameter int MAX_BURST = 16,
  parameter int FIFO_DEPTH = 64
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave (register access)
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // AXI4 memory-mapped master (32 bit data)
  output logic [31:0] m_axi_awaddr,
  output logic [7:0]  m_axi_awlen,
  output logic [2:0]  m_axi_awsize,
  output logic [1:0]  m_axi_awburst,
  output logic        m_axi_awvalid,
  input  logic        m_axi_awready,
  output logic [31:0] m_axi_wdata,
  output logic [3:0]  m_axi_wstrb,
  output logic        m_axi_wlast,
  output logic        m_axi_wvalid,
  input  logic        m_axi_wready,
  input  logic [1:0]  m_axi_bresp,
  input  logic        m_axi_bvalid,
  output logic        m_axi_bready,
  output logic [31:0] m_axi_araddr,
  output logic [7:0]  m_axi_arlen,
  output logic [2:0]  m_axi_arsize,
  output logic [1:0]  m_axi_arburst,
  output logic        m_axi_arvalid,
  input  logic        m_axi_arready,
  input  logic [31:0] m_axi_rdata,
  input  logic [1:0]  m_axi_rresp,
  input  logic        m_axi_rlast,
  input  logic        m_axi_rvalid,
  output logic        m_axi_rready,
  output logic irq_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (MAX_BURST < 1 || MAX_BURST > 256) begin : g_chk_mb $error("%m: MAX_BURST must be 1..256 (AXI4 limit)"); end
  if (FIFO_DEPTH < MAX_BURST) begin : g_chk_fd $error("%m: FIFO_DEPTH must hold a full burst"); end

`ifndef SYNTHESIS
  // verification-only checks: excluded from code coverage
  // verilator coverage_off
  // ---- immediate assertions (simulation only; skipped by synthesis) ----
  logic ip_chk_b_q, ip_chk_r_q;
  always @(posedge aclk) begin
    if (aresetn) begin
      ip_chk_b_q <= s_axil_bvalid & ~s_axil_bready;
      ip_chk_r_q <= s_axil_rvalid & ~s_axil_rready;
      assert (s_axil_bresp == 2'b00 || s_axil_bresp == 2'b10) else $error("%m: reserved BRESP value");
      assert (s_axil_rresp == 2'b00 || s_axil_rresp == 2'b10) else $error("%m: reserved RRESP value");
      if (ip_chk_b_q) assert (s_axil_bvalid) else $error("%m: BVALID dropped before BREADY");
      if (ip_chk_r_q) assert (s_axil_rvalid) else $error("%m: RVALID dropped before RREADY");
    end else begin
      ip_chk_b_q <= 1'b0;
      ip_chk_r_q <= 1'b0;
    end
  end
  // verilator coverage_on
`endif

  logic [5*32-1:0] regs, rd;
  logic [4:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(5)) u_regs (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .reg_o(regs),
    .wr_pulse_o(wr_pulse),
    .wr_data_o(wr_data),
    .rd_i(rd)
  );

  wire [31:0] src = regs[32 +: 32], dst = regs[64 +: 32], len = regs[96 +: 32];
  logic start_p;
  logic bad_len;
  wire  rd_busy, wr_busy, rd_done, wr_done, rd_err, wr_err;
  logic done_f, err_f;
  wire  busy = rd_busy | wr_busy;

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      start_p <= 1'b0;
      done_f <= 1'b0;
      err_f <= 1'b0;
    end
    else begin
      // Start only if idle and the length is a non-zero multiple of 4
      start_p <= wr_pulse[0] & wr_data[0] & ~busy;
      if (wr_pulse[0] & wr_data[0] & ~busy & (len[1:0] != 2'b00 || len == 32'd0)) err_f <= 1'b1;
      if (wr_done) begin
        done_f <= 1'b1;
        if (rd_err | wr_err) err_f <= 1'b1;
      end
      if (wr_pulse[4]) begin
        if (wr_data[8]) done_f <= 1'b0;
        if (wr_data[9]) err_f  <= 1'b0;
      end
    end
  end
  wire go = start_p & (len[1:0] == 2'b00) & (len != 32'd0);

  // Read engine -> FIFO -> write engine
  logic [31:0] rd_t, wr_t;
  logic rd_tv, rd_tr, rd_tl, wr_tv, wr_tr, wr_tl, wr_tu;
  logic [$clog2(FIFO_DEPTH)+1:0] lvl;
  logic fu;
  dma_rd_engine #(.ADDR_W(32), .MAX_BURST(MAX_BURST)) u_rd (
    .clk(aclk),
    .rst_n(aresetn),
    .start_i(go),
    .addr_i(src),
    .nwords_i(len[25:2]),
    .busy_o(rd_busy),
    .done_o(rd_done),
    .err_o(rd_err),
    .m_axi_araddr,
    .m_axi_arlen,
    .m_axi_arsize,
    .m_axi_arburst,
    .m_axi_arvalid,
    .m_axi_arready,
    .m_axi_rdata,
    .m_axi_rresp,
    .m_axi_rlast,
    .m_axi_rvalid,
    .m_axi_rready,
    .m_tdata(rd_t),
    .m_tvalid(rd_tv),
    .m_tready(rd_tr),
    .m_tlast(rd_tl)
  );
  ip_axis_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_fifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(rd_t),
    .s_tlast(rd_tl),
    .s_tuser(1'b0),
    .s_tvalid(rd_tv),
    .s_tready(rd_tr),
    .m_tdata(wr_t),
    .m_tlast(wr_tl),
    .m_tuser(wr_tu),
    .m_tvalid(wr_tv),
    .m_tready(wr_tr),
    .level_o(lvl)
  );
  dma_wr_engine #(.ADDR_W(32), .MAX_BURST(MAX_BURST)) u_wr (
    .clk(aclk),
    .rst_n(aresetn),
    .start_i(go),
    .addr_i(dst),
    .nwords_i(len[25:2]),
    .busy_o(wr_busy),
    .done_o(wr_done),
    .err_o(wr_err),
    .s_tdata(wr_t),
    .s_tvalid(wr_tv),
    .s_tready(wr_tr),
    .m_axi_awaddr,
    .m_axi_awlen,
    .m_axi_awsize,
    .m_axi_awburst,
    .m_axi_awvalid,
    .m_axi_awready,
    .m_axi_wdata,
    .m_axi_wstrb,
    .m_axi_wlast,
    .m_axi_wvalid,
    .m_axi_wready,
    .m_axi_bresp,
    .m_axi_bvalid,
    .m_axi_bready
  );

  assign irq_o = done_f & regs[1];
  assign rd = {32'd0, {22'd0, err_f, done_f, 7'd0, busy}, regs[3*32 +: 32], regs[2*32 +: 32], regs[32 +: 32], regs[31:0]};
endmodule
