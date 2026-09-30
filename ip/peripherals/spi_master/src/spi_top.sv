// ***************
// Filename: spi_top.sv
// Author: Paul Barcelona
// Description: SPI master IP top level. AXI-Stream slave carries words to
//   transmit (tlast ends a chip select burst), AXI-Stream master returns
//   the words captured from MISO. AXI-Lite map - 0x00 CTRL [0]en [1]cpol
//   [2]cpha [3]lsb_first [15:8]cs_select; 0x04 DIV (SCLK half period =
//   DIV+1 clocks); 0x08 WORD_LEN bits per word (1..DATA_W); 0x0C STATUS
//   [0]busy [1]rx_overrun (W1C) [31:16]rx fifo level. Any clock frequency,
//   default 1 MHz SCLK at 100 MHz. Version 1.0.0. Clock - single clock
//   aclk, every input is synchronous to it unless a two-flop synchronizer
//   is mentioned. Reset - synchronous active low aresetn, registers take
//   the documented reset values. Latency - AXI-Lite write response and
//   read data follow the request by about 2 to 3 clocks (ip_axil_regs,
//   registered read path). Timing - registered outputs, no combinational
//   path from the bus to the pins. Errors - out of range AXI-Lite accesses
//   return SLVERR; illegal parameter values stop elaboration with an
//   $error.
// Date: 2026-09-29
module spi_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCLK_HZ    = 1_000_000,     // default SCLK frequency
  parameter int DATA_W     = 32,            // max bits per word
  parameter int NUM_CS     = 4,
  parameter int FIFO_DEPTH = 512
) (
  input  logic               aclk,
  input  logic               aresetn,
  // AXI4-Lite slave
  input  logic [7:0]         s_axil_awaddr,
  input  logic               s_axil_awvalid,
  output logic               s_axil_awready,
  input  logic [31:0]        s_axil_wdata,
  input  logic [3:0]         s_axil_wstrb,
  input  logic               s_axil_wvalid,
  output logic               s_axil_wready,
  output logic [1:0]         s_axil_bresp,
  output logic               s_axil_bvalid,
  input  logic               s_axil_bready,
  input  logic [7:0]         s_axil_araddr,
  input  logic               s_axil_arvalid,
  output logic               s_axil_arready,
  output logic [31:0]        s_axil_rdata,
  output logic [1:0]         s_axil_rresp,
  output logic               s_axil_rvalid,
  input  logic               s_axil_rready,
  // AXI4-Stream slave: words to send (MOSI)
  input  logic [DATA_W-1:0]  s_axis_tdata,
  input  logic               s_axis_tvalid,
  output logic               s_axis_tready,
  input  logic               s_axis_tlast,
  // AXI4-Stream master: words received (MISO)
  output logic [DATA_W-1:0]  m_axis_tdata,
  output logic               m_axis_tvalid,
  input  logic               m_axis_tready,
  output logic               m_axis_tlast,
  // SPI pins
  output logic               spi_sclk_o,
  output logic               spi_mosi_o,
  input  logic               spi_miso_i,
  output logic [NUM_CS-1:0]  spi_cs_n_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (CLK_HZ < 1 || SCLK_HZ < 1 || SCLK_HZ * 2 > CLK_HZ) begin : g_chk_rate $error("%m: need SCLK_HZ*2 <= CLK_HZ"); end
  if (DATA_W < 1 || DATA_W > 32) begin : g_chk_dw $error("%m: DATA_W must be 1..32"); end
  if (NUM_CS < 1 || NUM_CS > 8) begin : g_chk_cs $error("%m: NUM_CS must be 1..8"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end

`ifndef SYNTHESIS
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
    end else begin ip_chk_b_q <= 1'b0; ip_chk_r_q <= 1'b0; end
  end
`endif

  localparam int DIV_DEF = (CLK_HZ / (2 * SCLK_HZ)) - 1;
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  localparam logic [4*32-1:0] RSTV = {32'd0, 32'd8, 32'(DIV_DEF), 32'd0};

  logic [4*32-1:0] regs, rd;
  logic [3:0]      wr_pulse;
  logic [31:0]     wr_data;
  ip_axil_regs #(.ADDR_W(8), .NREG(4), .RESET_VALS(RSTV)) u_regs (
    .aclk, .aresetn,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .reg_o(regs), .wr_pulse_o(wr_pulse), .wr_data_o(wr_data), .rd_i(rd));

  // Transmit FIFO -> engine
  logic [DATA_W-1:0] txf_data; logic txf_valid, txf_ready, txf_last, txf_user;
  logic [LW-1:0]     txf_lvl, rxf_lvl;
  ip_axis_fifo #(.DATA_W(DATA_W), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(s_axis_tdata), .s_tlast(s_axis_tlast), .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(txf_data), .m_tlast(txf_last), .m_tuser(txf_user),
    .m_tvalid(txf_valid), .m_tready(txf_ready), .level_o(txf_lvl));

  // Engine
  logic [DATA_W-1:0] rx_data; logic rx_last, rx_valid, busy, rxf_ready;
  spi_engine #(.DATA_W(DATA_W), .NUM_CS(NUM_CS)) u_eng (
    .clk(aclk), .rst_n(aresetn), .enable_i(regs[0]), .cpol_i(regs[1]),
    .cpha_i(regs[2]), .lsb_first_i(regs[3]),
    .word_len_i(regs[64 +: 6]), .div_i(regs[32 +: 16]),
    .cs_sel_i(regs[8 +: $clog2(NUM_CS)]),
    .tx_data(txf_data), .tx_last(txf_last), .tx_valid(txf_valid),
    .tx_ready(txf_ready), .rx_data(rx_data), .rx_last(rx_last),
    .rx_valid(rx_valid), .sclk_o(spi_sclk_o), .mosi_o(spi_mosi_o),
    .miso_i(spi_miso_i), .cs_n_o(spi_cs_n_o), .busy_o(busy));

  // Receive FIFO
  logic rxf_user;
  ip_axis_fifo #(.DATA_W(DATA_W), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(rx_data), .s_tlast(rx_last), .s_tuser(1'b0),
    .s_tvalid(rx_valid), .s_tready(rxf_ready),
    .m_tdata(m_axis_tdata), .m_tlast(m_axis_tlast), .m_tuser(rxf_user),
    .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready), .level_o(rxf_lvl));

  // Overrun flag: a received word was dropped because the FIFO was full
  logic overrun;
  always_ff @(posedge aclk) begin
    if (!aresetn) overrun <= 1'b0;
    else begin
      if (rx_valid & ~rxf_ready) overrun <= 1'b1;
      if (wr_pulse[3] & wr_data[1]) overrun <= 1'b0;   // W1C
    end
  end

  wire [31:0] status = {16'(rxf_lvl), 14'd0, overrun, busy};
  assign rd = {status, regs[95:0]};
endmodule
