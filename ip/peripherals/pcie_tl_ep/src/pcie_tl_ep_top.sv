// ***************
// Filename: pcie_tl_ep_top.sv
// Author: FPGA Cores 4 U
// Description: PCIe transaction layer endpoint IP top level. 64 bit
//   AXI-Stream TLP ports (rx from and tx to a PCIe link core such as a hard
//   block), Type 0 config space, BAR0 with block RAM and a stream window,
//   plus AXI-Stream user ports - s_axis words are DMA written to host memory
//   as Memory Write TLPs, m_axis carries payload written to the BAR0 stream
//   window. AXI-Lite map - 0x00 CTRL[0]=dma_en; 0x04/0x08 DMA_ADDR lo/hi;
//   0x0C DMA_LEN_DW; 0x10 STATUS [0]mem_en [1]bus_master [2]dma_busy; 0x14
//   CPL_ID; 0x18 BAR0; 0x1C RX_TLP; 0x20 MWR; 0x24 MRD; 0x28 CFG; 0x2C UR;
//   0x30 DMA_TLP counters. PHY, LTSSM and data link layer are not included.
//   Version 1.0.0. Scope - transaction layer only (no PHY, data link layer,
//   LTSSM, credit or flow-control logic; a link core must supply the TLP
//   stream). Clock - aclk (250 MHz class for a Gen2 x4 link core, 100 MHz
//   used in simulation), everything synchronous. Reset - synchronous aresetn,
//   DMA idle, counters cleared, BAR RAM contents undefined. Latency - a
//   memory read is answered with a completion about 5 clocks after the
//   request TLP ends; a memory write reaches the RAM 2 clocks after the last
//   beat. Errors - unsupported requests are answered with an Unsupported
//   Request completion and counted (UR counter); illegal parameters stop
//   elaboration.
// Date: 2026-09-29
module pcie_tl_ep_top #(
  parameter logic [15:0] VENDOR_ID = 16'h1234,
  parameter logic [15:0] DEVICE_ID = 16'h5678,
  parameter int          BAR_BITS  = 13,
  parameter int          RAM_DW    = 1024,
  parameter int          FIFO_DEPTH = 512
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave
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
  // TLP receive (from link)
  input  logic [63:0] rx_axis_tdata,
  input  logic [7:0]  rx_axis_tkeep,
  input  logic        rx_axis_tlast,
  input  logic        rx_axis_tvalid,
  output logic        rx_axis_tready,
  // TLP transmit (to link)
  output logic [63:0] tx_axis_tdata,
  output logic [7:0]  tx_axis_tkeep,
  output logic        tx_axis_tlast,
  output logic        tx_axis_tvalid,
  input  logic        tx_axis_tready,
  // User stream into DMA (device -> host)
  input  logic [31:0] s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // User stream from BAR0 stream window (host -> device)
  output logic [31:0] m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (BAR_BITS < 6 || BAR_BITS > 24) begin : g_chk_bar $error("pcie_tl_ep_top: BAR_BITS must be 6..24"); end
  if (RAM_DW < 4 || RAM_DW * 4 > (1 << (BAR_BITS - 1))) begin : g_chk_ram $error("pcie_tl_ep_top: RAM_DW must fit in the lower BAR half"); end
  if (FIFO_DEPTH < 4 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fifo $error("pcie_tl_ep_top: FIFO_DEPTH must be a power of two >= 4"); end
  localparam int NREG = 13;
  localparam int LW   = $clog2(FIFO_DEPTH) + 2;
  localparam logic [NREG*32-1:0] RSTV = {
    {9{32'd0}}, 32'd8, 32'd0, 32'd0, 32'd0};       // reg3 DMA_LEN = 8

  logic [NREG*32-1:0] regs, rd;
  logic [NREG-1:0]    wr_pulse;
  logic [31:0]        wr_data;
  pcie_axil_regs #(.ADDR_W(8), .NREG(NREG), .RESET_VALS(RSTV)) u_regs (
    .aclk, .aresetn,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));

  // ---- Receive path: 64 bit beats -> DWs -> target ----
  logic [31:0] rx_dw;  logic rx_dw_last, rx_dw_valid, rx_dw_ready;
  pcie_axis_to_dw u_rx_conv (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(rx_axis_tdata), .s_tkeep(rx_axis_tkeep), .s_tlast(rx_axis_tlast),
    .s_tvalid(rx_axis_tvalid), .s_tready(rx_axis_tready),
    .dw_data(rx_dw), .dw_last(rx_dw_last), .dw_valid(rx_dw_valid),
    .dw_ready(rx_dw_ready));

  logic [31:0] cpl_dw;  logic cpl_last, cpl_valid, cpl_ready;
  logic [31:0] str_dw;  logic str_last, str_valid, str_ready;
  logic        mem_en, bus_master;
  logic [15:0] cpl_id;
  logic [31:0] bar0;
  logic        p_rx, p_mwr, p_mrd, p_cfg, p_ur;
  pcie_tl_target #(.VENDOR_ID(VENDOR_ID), .DEVICE_ID(DEVICE_ID),
                   .BAR_BITS(BAR_BITS), .RAM_DW(RAM_DW)) u_tgt (
    .clk(aclk), .rst_n(aresetn),
    .rx_dw, .rx_last(rx_dw_last), .rx_valid(rx_dw_valid), .rx_ready(rx_dw_ready),
    .cpl_dw, .cpl_last, .cpl_valid, .cpl_ready,
    .str_dw, .str_last, .str_valid, .str_ready,
    .mem_en_o(mem_en), .bus_master_o(bus_master), .cpl_id_o(cpl_id),
    .bar0_o(bar0), .p_rx_tlp(p_rx), .p_mwr, .p_mrd, .p_cfg, .p_ur);

  // ---- BAR0 stream window -> m_axis FIFO ----
  logic [LW-1:0] mf_lvl; logic mf_user;
  pcie_axis_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_mfifo (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(str_dw), .s_tlast(str_last), .s_tuser(1'b0),
    .s_tvalid(str_valid), .s_tready(str_ready),
    .m_tdata(m_axis_tdata), .m_tlast(m_axis_tlast), .m_tuser(mf_user),
    .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready), .level_o(mf_lvl));

  // ---- DMA source FIFO and engine ----
  logic [31:0] sf_data; logic sf_valid, sf_ready, sf_last, sf_user;
  logic [LW-1:0] sf_lvl;
  pcie_axis_fifo #(.DATA_W(32), .DEPTH(FIFO_DEPTH)) u_sfifo (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(s_axis_tdata), .s_tlast(s_axis_tlast), .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(sf_data), .m_tlast(sf_last), .m_tuser(sf_user),
    .m_tvalid(sf_valid), .m_tready(sf_ready), .level_o(sf_lvl));

  logic [31:0] dma_dw; logic dma_last, dma_valid, dma_ready;
  logic        dma_busy, dma_tlp;
  logic [63:0] dma_cur;
  pcie_tl_dma u_dma (
    .clk(aclk), .rst_n(aresetn), .en_i(regs[0]), .bus_master_i(bus_master),
    .req_id_i(cpl_id), .addr_load_i(wr_pulse[1] | wr_pulse[2]),
    .addr_i({regs[95:64], regs[63:32]}), .len_dw_i(regs[96 +: 10]),
    .f_data(sf_data), .f_valid(sf_valid), .f_ready(sf_ready),
    .f_level(16'(sf_lvl)),
    .tx_dw(dma_dw), .tx_last(dma_last), .tx_valid(dma_valid), .tx_ready(dma_ready),
    .busy_o(dma_busy), .tlp_o(dma_tlp), .cur_addr_o(dma_cur));

  // ---- Transmit arbiter: completions win, packets are never interleaved ----
  logic [1:0]  owner;                       // 0 free, 1 completion, 2 DMA
  logic [31:0] tx_dw; logic tx_last, tx_valid, tx_ready;
  wire sel_cpl = (owner == 2'd1) || (owner == 2'd0 && cpl_valid);
  wire sel_dma = (owner == 2'd2) || (owner == 2'd0 && !cpl_valid && dma_valid);
  assign tx_dw     = sel_cpl ? cpl_dw : dma_dw;
  assign tx_last   = sel_cpl ? cpl_last : dma_last;
  assign tx_valid  = sel_cpl ? cpl_valid : (sel_dma & dma_valid);
  assign cpl_ready = sel_cpl & tx_ready;
  assign dma_ready = sel_dma & tx_ready;
  always_ff @(posedge aclk) begin
    if (!aresetn) owner <= 2'd0;
    else if (tx_valid & tx_ready) begin
      if (tx_last)             owner <= 2'd0;
      else if (owner == 2'd0)  owner <= sel_cpl ? 2'd1 : 2'd2;
    end
  end

  pcie_dw_to_axis u_tx_conv (
    .clk(aclk), .rst_n(aresetn),
    .dw_data(tx_dw), .dw_last(tx_last), .dw_valid(tx_valid), .dw_ready(tx_ready),
    .m_tdata(tx_axis_tdata), .m_tkeep(tx_axis_tkeep), .m_tlast(tx_axis_tlast),
    .m_tvalid(tx_axis_tvalid), .m_tready(tx_axis_tready));

  // ---- Event counters ----
  logic [31:0] c_rx, c_mwr, c_mrd, c_cfg, c_ur, c_dma;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      c_rx <= '0; c_mwr <= '0; c_mrd <= '0; c_cfg <= '0; c_ur <= '0; c_dma <= '0;
    end else begin
      if (p_rx)    c_rx  <= c_rx  + 32'd1;
      if (p_mwr)   c_mwr <= c_mwr + 32'd1;
      if (p_mrd)   c_mrd <= c_mrd + 32'd1;
      if (p_cfg)   c_cfg <= c_cfg + 32'd1;
      if (p_ur)    c_ur  <= c_ur  + 32'd1;
      if (dma_tlp) c_dma <= c_dma + 32'd1;
    end
  end

  wire [31:0] status = {16'(sf_lvl), 13'd0, dma_busy, bus_master, mem_en};
  assign rd = {c_dma, c_ur, c_cfg, c_mrd, c_mwr, c_rx, bar0, 16'd0, cpl_id,
               status, regs[127:0]};
endmodule
