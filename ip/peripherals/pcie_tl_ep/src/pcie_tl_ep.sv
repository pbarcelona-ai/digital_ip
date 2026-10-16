// ***************
// Filename: pcie_tl_ep.sv
// Author: FPGA Cores 4 U
// Description: PCIe transaction layer endpoint IP top level. 64 bit
//   AXI-Stream TLP ports (rx from and tx to a PCIe link core such as a hard
//   block), Type 0 config space, BAR0 with block RAM and a stream window,
//   plus AXI-Stream user ports - s_axis words are DMA written to host memory
//   as Memory Write TLPs, m_axis carries payload written to the BAR0 stream
//   window. Registers on the cfg_* / sts_* ports; pcie_tl_ep_top.sv is the
//   block with its AXI4-Lite register map (src/include/pcie_tl_ep_regs.sv: ID
//   "PCIE" / VERSION / DATE at 0x00-0x08) - 0x10 CTRL[0]=dma_en; 0x14/0x18
//   DMA_ADDR lo/hi; 0x1C DMA_LEN_DW; 0x20 STATUS [0]mem_en [1]bus_master
//   [2]dma_busy; 0x24 CPL_ID; 0x28 BAR0; 0x2C RX_TLP; 0x30 MWR; 0x34 MRD;
//   0x38 CFG; 0x3C UR; 0x40 DMA_TLP counters. PHY, LTSSM and data link layer are not included.
//   Scope - transaction layer only (no PHY, data link layer,
//   LTSSM, credit or flow-control logic; a link core must supply the TLP
//   stream). Clock - aclk (250 MHz class for a Gen2 x4 link core, 100 MHz
//   used in simulation), everything synchronous. Reset - synchronous aresetn,
//   DMA idle, counters cleared, BAR RAM contents undefined. Latency - a
//   memory read is answered with a completion about 5 clocks after the
//   request TLP ends; a memory write reaches the RAM 2 clocks after the last
//   beat. Errors - unsupported requests are answered with an Unsupported
//   Request completion and counted (UR counter); illegal parameters stop
//   elaboration.
// Date: 2026-10-12
module pcie_tl_ep #(
  parameter logic [15:0] VENDOR_ID = 16'h1234,
  parameter logic [15:0] DEVICE_ID = 16'h5678,
  parameter int          BAR_BITS  = 13,
  parameter int          RAM_DW    = 1024,
  parameter int          FIFO_DEPTH = 512
) (

  input  logic        aclk,
  input  logic        aresetn,
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
  output logic        m_axis_tlast,
  // register ports
  input  logic        cfg_ctrl,             // CTRL
  input  logic [31:0] cfg_dma_addr_lo,      // DMA_ADDR_LO
  input  logic        cfg_dma_addr_lo_wr,
  input  logic [31:0] cfg_dma_addr_hi,      // DMA_ADDR_HI
  input  logic        cfg_dma_addr_hi_wr,
  input  logic [9:0]  cfg_dma_len_dw,       // DMA_LEN_DW
  output logic [31:0] sts_status,           // STATUS
  output logic [15:0] sts_cpl_id,           // CPL_ID
  output logic [31:0] sts_bar0,             // BAR0
  output logic [31:0] sts_rx_tlp,           // RX_TLP
  output logic [31:0] sts_mwr,              // MWR
  output logic [31:0] sts_mrd,              // MRD
  output logic [31:0] sts_cfg,              // CFG
  output logic [31:0] sts_ur,               // UR
  output logic [31:0] sts_dma_tlp           // DMA_TLP
);
  if (BAR_BITS < 6 || BAR_BITS > 24) begin : g_chk_bar $error("pcie_tl_ep: BAR_BITS must be 6..24"); end
  if (RAM_DW < 4 || RAM_DW * 4 > (1 << (BAR_BITS - 1))) begin : g_chk_ram $error("pcie_tl_ep: RAM_DW must fit in the lower BAR half"); end
  if (FIFO_DEPTH < 4 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fifo $error("pcie_tl_ep: FIFO_DEPTH must be a power of two >= 4"); end
  localparam int LW   = $clog2(FIFO_DEPTH) + 2;

  // ---- Receive path: 64 bit beats -> DWs -> target ----
  logic [31:0] rx_dw;
  logic rx_dw_last, rx_dw_valid, rx_dw_ready;
  pcie_axis_to_dw u_rx_conv (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(rx_axis_tdata),
    .s_tkeep(rx_axis_tkeep),
    .s_tlast(rx_axis_tlast),
    .s_tvalid(rx_axis_tvalid),
    .s_tready(rx_axis_tready),
    .dw_data(rx_dw),
    .dw_last(rx_dw_last),
    .dw_valid(rx_dw_valid),
    .dw_ready(rx_dw_ready)
  );

  logic [31:0] cpl_dw;
  logic cpl_last, cpl_valid, cpl_ready;
  logic [31:0] str_dw;
  logic str_last, str_valid, str_ready;
  logic        mem_en, bus_master;
  logic [15:0] cpl_id;
  logic [31:0] bar0;
  logic        p_rx, p_mwr, p_mrd, p_cfg, p_ur;
  pcie_tl_target #(
    .VENDOR_ID(VENDOR_ID),
    .DEVICE_ID(DEVICE_ID),
    .BAR_BITS(BAR_BITS),
    .RAM_DW(RAM_DW)
  ) u_tgt (
    .clk(aclk),
    .rst_n(aresetn),
    .rx_dw,
    .rx_last(rx_dw_last),
    .rx_valid(rx_dw_valid),
    .rx_ready(rx_dw_ready),
    .cpl_dw,
    .cpl_last,
    .cpl_valid,
    .cpl_ready,
    .str_dw,
    .str_last,
    .str_valid,
    .str_ready,
    .mem_en_o(mem_en),
    .bus_master_o(bus_master),
    .cpl_id_o(cpl_id),
    .bar0_o(bar0),
    .p_rx_tlp(p_rx),
    .p_mwr,
    .p_mrd,
    .p_cfg,
    .p_ur
  );

  // ---- BAR0 stream window -> m_axis FIFO ----
  logic [LW-1:0] mf_lvl;
  logic mf_user;
  pcie_axis_fifo #(
    .DATA_W(32),
    .DEPTH(FIFO_DEPTH)
  ) u_mfifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(str_dw),
    .s_tlast(str_last),
    .s_tuser(1'b0),
    .s_tvalid(str_valid),
    .s_tready(str_ready),
    .m_tdata(m_axis_tdata),
    .m_tlast(m_axis_tlast),
    .m_tuser(mf_user),
    .m_tvalid(m_axis_tvalid),
    .m_tready(m_axis_tready),
    .level_o(mf_lvl)
  );

  // ---- DMA source FIFO and engine ----
  logic [31:0] sf_data;
  logic sf_valid, sf_ready, sf_last, sf_user;
  logic [LW-1:0] sf_lvl;
  pcie_axis_fifo #(
    .DATA_W(32),
    .DEPTH(FIFO_DEPTH)
  ) u_sfifo (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(s_axis_tdata),
    .s_tlast(s_axis_tlast),
    .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid),
    .s_tready(s_axis_tready),
    .m_tdata(sf_data),
    .m_tlast(sf_last),
    .m_tuser(sf_user),
    .m_tvalid(sf_valid),
    .m_tready(sf_ready),
    .level_o(sf_lvl)
  );

  logic [31:0] dma_dw;
  logic dma_last, dma_valid, dma_ready;
  logic        dma_busy, dma_tlp;
  logic [63:0] dma_cur;
  pcie_tl_dma u_dma (
    .clk(aclk),
    .rst_n(aresetn),
    .en_i(cfg_ctrl),
    .bus_master_i(bus_master),
    .req_id_i(cpl_id),
    .addr_load_i(cfg_dma_addr_lo_wr | cfg_dma_addr_hi_wr),
    .addr_i({cfg_dma_addr_hi, cfg_dma_addr_lo}),
    .len_dw_i(cfg_dma_len_dw),
    .f_data(sf_data),
    .f_valid(sf_valid),
    .f_ready(sf_ready),
    .f_level(16'(sf_lvl)),
    .tx_dw(dma_dw),
    .tx_last(dma_last),
    .tx_valid(dma_valid),
    .tx_ready(dma_ready),
    .busy_o(dma_busy),
    .tlp_o(dma_tlp),
    .cur_addr_o(dma_cur)
  );

  // ---- Transmit arbiter: completions win, packets are never interleaved ----
  logic [1:0]  owner;                       // 0 free, 1 completion, 2 DMA
  logic [31:0] tx_dw;
  logic tx_last, tx_valid, tx_ready;
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
    .clk(aclk),
    .rst_n(aresetn),
    .dw_data(tx_dw),
    .dw_last(tx_last),
    .dw_valid(tx_valid),
    .dw_ready(tx_ready),
    .m_tdata(tx_axis_tdata),
    .m_tkeep(tx_axis_tkeep),
    .m_tlast(tx_axis_tlast),
    .m_tvalid(tx_axis_tvalid),
    .m_tready(tx_axis_tready)
  );

  // ---- Event counters ----
  logic [31:0] c_rx, c_mwr, c_mrd, c_cfg, c_ur, c_dma;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      c_rx <= '0;
      c_mwr <= '0;
      c_mrd <= '0;
      c_cfg <= '0;
      c_ur <= '0;
      c_dma <= '0;
    end else begin
      if (p_rx)    c_rx  <= c_rx  + 32'd1;
      if (p_mwr)   c_mwr <= c_mwr + 32'd1;
      if (p_mrd)   c_mrd <= c_mrd + 32'd1;
      if (p_cfg)   c_cfg <= c_cfg + 32'd1;
      if (p_ur)    c_ur  <= c_ur  + 32'd1;
      if (dma_tlp) c_dma <= c_dma + 32'd1;
    end
  end

  assign sts_status = {16'(sf_lvl), 13'd0, dma_busy, bus_master, mem_en};
  assign sts_cpl_id = cpl_id;
  assign sts_bar0 = bar0;
  assign sts_rx_tlp = c_rx;
  assign sts_mwr = c_mwr;
  assign sts_mrd = c_mrd;
  assign sts_cfg = c_cfg;
  assign sts_ur = c_ur;
  assign sts_dma_tlp = c_dma;
endmodule
