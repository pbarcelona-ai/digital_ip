// ***************
// Filename: axis_dma.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream DMA with two independent channels sharing one AXI4
//   master port. MM2S reads LEN bytes from memory and emits them on an
//   AXI-Stream master (tlast on the last word). S2MM accepts an AXI-Stream
//   slave and writes LEN bytes to memory. Both use burst engines limited to
//   MAX_BURST beats and 4 KB boundaries, with FIFOs on the stream sides.
//   AXI-Lite map - 0x00 CTRL [0]mm2s_start [1]s2mm_start (pulses) [2]irq_en,
//   0x04 MM2S_ADDR, 0x08 MM2S_LEN, 0x0C S2MM_ADDR, 0x10 S2MM_LEN, 0x14 STATUS
//   [0]mm2s_busy [1]s2mm_busy [8]mm2s_done [9]s2mm_done [10]mm2s_err
//   [11]s2mm_err, done and error bits are W1C. Version 1.0.0. Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error. The AXI4 master follows the AXI4 rules of 4
//   KB burst boundaries; a bus error response stops the transfer and is
//   reported in STATUS.
// Date: 2026-09-29
module axis_dma #(
  parameter int MAX_BURST  = 16,
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
  // MM2S stream out (memory -> stream)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // S2MM stream in (stream -> memory)
  input  logic [31:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  output logic        irq_o
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

  logic [6*32-1:0] regs, rd;
  logic [5:0] wr_pulse;
  logic [31:0] wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(6)) u_regs (
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

  wire [31:0] mm_addr = regs[32 +: 32], mm_len = regs[64 +: 32];
  wire [31:0] s2_addr = regs[96 +: 32], s2_len = regs[128 +: 32];
  logic rd_busy, wr_busy, rd_done, wr_done, rd_err, wr_err;
  logic mm_go, s2_go, mm_done_f, s2_done_f, mm_err_f, s2_err_f;
  wire mm_ok = (mm_len[1:0] == 2'b00) && (mm_len != 32'd0);
  wire s2_ok = (s2_len[1:0] == 2'b00) && (s2_len != 32'd0);

  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      mm_go <= 1'b0;
      s2_go <= 1'b0;
      mm_done_f <= 1'b0;
      s2_done_f <= 1'b0;
      mm_err_f <= 1'b0;
      s2_err_f <= 1'b0;
    end else begin
      mm_go <= wr_pulse[0] & wr_data[0] & ~rd_busy & mm_ok;
      s2_go <= wr_pulse[0] & wr_data[1] & ~wr_busy & s2_ok;
      if (wr_pulse[0] & wr_data[0] & ~rd_busy & ~mm_ok) mm_err_f <= 1'b1;
      if (wr_pulse[0] & wr_data[1] & ~wr_busy & ~s2_ok) s2_err_f <= 1'b1;
      if (rd_done) begin
        mm_done_f <= 1'b1;
        if (rd_err) mm_err_f <= 1'b1;
      end
      if (wr_done) begin
        s2_done_f <= 1'b1;
        if (wr_err) s2_err_f <= 1'b1;
      end
      if (wr_pulse[5]) begin
        if (wr_data[8])  mm_done_f <= 1'b0;
        if (wr_data[9])  s2_done_f <= 1'b0;
        if (wr_data[10]) mm_err_f  <= 1'b0;
        if (wr_data[11]) s2_err_f  <= 1'b0;
      end
    end
  end

  // MM2S: read engine -> FIFO -> stream master
  logic [31:0] rd_t;
  logic rd_tv, rd_tr, rd_tl, mu;
  logic [$clog2(FIFO_DEPTH)+1:0] l1, l2;
  logic su;
  dma_rd_engine #(.ADDR_W(32), .MAX_BURST(MAX_BURST)) u_rd (
    .clk(aclk),
    .rst_n(aresetn),
    .start_i(mm_go),
    .addr_i(mm_addr),
    .nwords_i(mm_len[25:2]),
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
  ip_axis_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_mm_fifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(rd_t),
    .s_tlast(rd_tl),
    .s_tuser(1'b0),
    .s_tvalid(rd_tv),
    .s_tready(rd_tr),
    .m_tdata(m_axis_tdata),
    .m_tlast(m_axis_tlast),
    .m_tuser(mu),
    .m_tvalid(m_axis_tvalid),
    .m_tready(m_axis_tready),
    .level_o(l1)
  );

  // S2MM: stream slave -> FIFO -> write engine
  logic [31:0] wr_t;
  logic wr_tv, wr_tr, wr_tl;
  ip_axis_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_s2_fifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(s_axis_tdata),
    .s_tlast(s_axis_tlast),
    .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid),
    .s_tready(s_axis_tready),
    .m_tdata(wr_t),
    .m_tlast(wr_tl),
    .m_tuser(su),
    .m_tvalid(wr_tv),
    .m_tready(wr_tr),
    .level_o(l2)
  );
  dma_wr_engine #(.ADDR_W(32), .MAX_BURST(MAX_BURST)) u_wr (
    .clk(aclk),
    .rst_n(aresetn),
    .start_i(s2_go),
    .addr_i(s2_addr),
    .nwords_i(s2_len[25:2]),
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

  assign irq_o = regs[2] & (mm_done_f | s2_done_f);
  assign rd = {32'd0, {20'd0, s2_err_f, mm_err_f, s2_done_f, mm_done_f, 6'd0, wr_busy, rd_busy}, regs[4*32 +: 32],
               regs[3*32 +: 32], regs[2*32 +: 32], regs[32 +: 32], regs[31:0]};
endmodule
