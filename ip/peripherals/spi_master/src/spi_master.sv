// ***************
// Filename: spi_master.sv
// Author: FPGA Cores 4 U
// Description: SPI master logic. AXI-Stream slave carries words to transmit
//   (tlast ends a chip select burst), AXI-Stream master returns the words
//   captured from MISO; the registers come and go on the cfg_* / sts_*
//   ports. spi_top.sv is the block with its AXI4-Lite register map
//   (src/include/spi_master_regs.sv: ID "SPIM" / VERSION / DATE at
//   0x00-0x08, CTRL 0x10 [0] en [1] cpol [2] cpha [3] lsb_first [15:8]
//   cs_select; DIV 0x14 (SCLK half period = DIV + 1 clocks, values below 2
//   act as 2: MISO is double registered); WORD_LEN 0x18 bits per word
//   (1..DATA_W, other values act as DATA_W); STATUS 0x1C [0] busy [1] rx_overrun (W1C)
//   [31:16] rx fifo level). Any clock frequency, default 1 MHz SCLK at
//   100 MHz. Clock - single clock aclk. Reset - synchronous active low
//   aresetn. Timing - registered outputs, no combinational path from the
//   bus to the pins. Errors - illegal parameter values stop elaboration
//   with an $error.
// Date: 2026-10-16
module spi_master #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int SCLK_HZ    = 1_000_000,     // default SCLK frequency
  parameter int DATA_W     = 32,            // max bits per word
  parameter int NUM_CS     = 4,
  parameter int FIFO_DEPTH = 512
) (
  input  logic               aclk,
  input  logic               aresetn,
  // AXI4-Stream slave: words to send (MOSI)
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.slave s_axis,
  // AXI4-Stream master: words received (MISO)
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.master m_axis,
  // SPI pins
  // spi: spi_if.master (ip/shared/src/interfaces/spi_if.sv), NUM_CS = NUM_CS {spi_sclk_o=sclk spi_mosi_o=mosi spi_miso_i=miso spi_cs_n_o=cs_n}
  spi_if.master spi,
  // register ports
  // regs: spi_master_regs_if.core (src/include/spi_master_regs_if.sv)
  spi_master_regs_if.core regs
);
  assign m_axis.tkeep = '1;      // not used by this block
  assign m_axis.tuser = '0;      // not used by this block
  if (CLK_HZ < 1 || SCLK_HZ < 1 || SCLK_HZ * 6 > CLK_HZ) begin : g_chk_rate $error("%m: need SCLK_HZ*6 <= CLK_HZ (DIV >= 2)"); end
  if (DATA_W < 1 || DATA_W > 32) begin : g_chk_dw $error("%m: DATA_W must be 1..32"); end
  if (NUM_CS < 1 || NUM_CS > 8) begin : g_chk_cs $error("%m: NUM_CS must be 1..8"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  localparam int CSW = (NUM_CS > 1) ? $clog2(NUM_CS) : 1;   // chip-select index width
  // MISO is double registered: a half period of at least 3 clocks (DIV >= 2) is needed; WORD_LEN
  // outside 1 .. DATA_W acts as DATA_W
  wire [15:0] div = (regs.cfg_div < 16'd2) ? 16'd2 : regs.cfg_div;
  wire [5:0]  wl  = (regs.cfg_word_len == 6'd0 || 32'(regs.cfg_word_len) > DATA_W) ? 6'(DATA_W) : regs.cfg_word_len;

  // Transmit FIFO -> engine
  axis_if #(.DATA_W(DATA_W), .USER_W(1)) txf ();
  logic [LW-1:0]     txf_lvl, rxf_lvl;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(FIFO_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(s_axis),
    .m(txf),
    .level_o(txf_lvl)
  );

  // Engine
  axis_if #(.DATA_W(DATA_W)) s ();
  assign s.tuser = 1'b0;
  logic busy;
  spi_engine #(
    .DATA_W(DATA_W),
    .NUM_CS(NUM_CS)
  ) u_eng (
    .clk(aclk),
    .rst_n(aresetn),
    .enable_i(regs.cfg_ctrl[0]),
    .cpol_i(regs.cfg_ctrl[1]),
    .cpha_i(regs.cfg_ctrl[2]),
    .lsb_first_i(regs.cfg_ctrl[3]),
    .word_len_i(wl),
    .div_i(div),
    .cs_sel_i(regs.cfg_ctrl[8 +: CSW]),
    .tx_data(txf.tdata),
    .tx_last(txf.tlast),
    .tx_valid(txf.tvalid),
    .tx_ready(txf.tready),
    .rx_data(s.tdata),
    .rx_last(s.tlast),
    .rx_valid(s.tvalid),
    .spi(spi),
    .busy_o(busy)
  );

  // Receive FIFO
  logic rxf_user;
  axis_if #(.DATA_W(DATA_W)) u_rxf_m ();
  assign m_axis.tdata = u_rxf_m.tdata;
  assign m_axis.tlast = u_rxf_m.tlast;
  assign rxf_user = u_rxf_m.tuser;
  assign m_axis.tvalid = u_rxf_m.tvalid;
  assign u_rxf_m.tready = m_axis.tready;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(FIFO_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(s),
    .m(u_rxf_m),
    .level_o(rxf_lvl)
  );

  // Overrun flag: a received word was dropped because the FIFO was full
  logic overrun;
  always_ff @(posedge aclk) begin
    if (!aresetn) overrun <= 1'b0;
    else begin
      if (regs.cfg_status_wr & regs.cfg_status[1]) overrun <= 1'b0;   // W1C first: a set in the same clock wins
      if (s.tvalid & ~s.tready) overrun <= 1'b1;
    end
  end

  assign regs.sts_status = {16'(rxf_lvl), 14'd0, overrun, busy};
endmodule
