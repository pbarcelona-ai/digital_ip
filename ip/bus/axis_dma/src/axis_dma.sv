// ***************
// Filename: axis_dma.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream DMA with two independent channels sharing one AXI4
//   master port. MM2S reads LEN bytes from memory and emits them on an
//   AXI-Stream master (tlast on the last word). S2MM accepts an AXI-Stream
//   slave and writes LEN bytes to memory. Both use burst engines limited to
//   MAX_BURST beats and 4 KB boundaries, with FIFOs on the stream sides.
//   Registers on the cfg_* / sts_* ports; axis_dma_top.sv is the block with
//   its AXI4-Lite register map (src/include/axis_dma_regs.sv: ID "ADMA" /
//   VERSION / DATE at 0x00-0x08) - 0x10 CTRL [0]mm2s_start [1]s2mm_start
//   (pulses) [2]irq_en, 0x14 MM2S_ADDR, 0x18 MM2S_LEN, 0x1C S2MM_ADDR,
//   0x20 S2MM_LEN, 0x24 STATUS
//   [0]mm2s_busy [1]s2mm_busy [8]mm2s_done [9]s2mm_done [10]mm2s_err
//   [11]s2mm_err, done and error bits are W1C. Clock - single
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
// Date: 2026-10-12
module axis_dma #(
  parameter int MAX_BURST  = 16,
  parameter int FIFO_DEPTH = 64
) (

  input  logic        aclk,
  input  logic        aresetn,
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
  output logic        irq_o,
  // register ports
  input  logic [2:0]  cfg_ctrl,          // CTRL
  input  logic        cfg_ctrl_wr,       // CTRL write pulse (start)
  input  logic [31:0] cfg_mm2s_addr,     // MM2S_ADDR
  input  logic [31:0] cfg_mm2s_len,      // MM2S_LEN
  input  logic [31:0] cfg_s2mm_addr,     // S2MM_ADDR
  input  logic [31:0] cfg_s2mm_len,      // S2MM_LEN
  input  logic [11:0] cfg_status,        // STATUS: data written ...
  input  logic        cfg_status_wr,     // ... and its write pulse
  output logic [11:0] sts_status         // STATUS: value read
);
  if (MAX_BURST < 1 || MAX_BURST > 256) begin : g_chk_mb $error("%m: MAX_BURST must be 1..256 (AXI4 limit)"); end
  if (FIFO_DEPTH < MAX_BURST) begin : g_chk_fd $error("%m: FIFO_DEPTH must hold a full burst"); end

  wire [31:0] mm_addr = cfg_mm2s_addr, mm_len = cfg_mm2s_len;
  wire [31:0] s2_addr = cfg_s2mm_addr, s2_len = cfg_s2mm_len;
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
      mm_go <= cfg_ctrl_wr & cfg_ctrl[0] & ~rd_busy & mm_ok;
      s2_go <= cfg_ctrl_wr & cfg_ctrl[1] & ~wr_busy & s2_ok;
      if (cfg_ctrl_wr & cfg_ctrl[0] & ~rd_busy & ~mm_ok) mm_err_f <= 1'b1;
      if (cfg_ctrl_wr & cfg_ctrl[1] & ~wr_busy & ~s2_ok) s2_err_f <= 1'b1;
      if (rd_done) begin
        mm_done_f <= 1'b1;
        if (rd_err) mm_err_f <= 1'b1;
      end
      if (wr_done) begin
        s2_done_f <= 1'b1;
        if (wr_err) s2_err_f <= 1'b1;
      end
      if (cfg_status_wr) begin
        if (cfg_status[8])  mm_done_f <= 1'b0;
        if (cfg_status[9])  s2_done_f <= 1'b0;
        if (cfg_status[10]) mm_err_f  <= 1'b0;
        if (cfg_status[11]) s2_err_f  <= 1'b0;
      end
    end
  end

  // MM2S: read engine -> FIFO -> stream master
  logic [31:0] rd_t;
  logic rd_tv, rd_tr, rd_tl, mu;
  logic [$clog2(FIFO_DEPTH)+1:0] l1, l2;
  logic su;
  dma_rd_engine #(
    .ADDR_W(32),
    .MAX_BURST(MAX_BURST)
  ) u_rd (
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
  ip_axis_fifo #(
    .DATA_W(32),
    .DEPTH(FIFO_DEPTH)
  ) u_mm_fifo (
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
  ip_axis_fifo #(
    .DATA_W(32),
    .DEPTH(FIFO_DEPTH)
  ) u_s2_fifo (
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
  dma_wr_engine #(
    .ADDR_W(32),
    .MAX_BURST(MAX_BURST)
  ) u_wr (
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

  assign irq_o = cfg_ctrl[2] & (mm_done_f | s2_done_f);
  assign sts_status = {s2_err_f, mm_err_f, s2_done_f, mm_done_f, 6'd0, wr_busy, rd_busy};
endmodule
