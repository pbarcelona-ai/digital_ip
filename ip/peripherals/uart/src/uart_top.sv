// ***************
// Filename: uart_top.sv
// Author: Paul Barcelona
// Description: UART IP top level. Full duplex UART with a fractional baud
//   generator, transmit and receive FIFOs (block RAM for deep FIFOs) and
//   AXI-Stream data ports: s_axis carries bytes to transmit, m_axis
//   carries received bytes. Control and status through AXI-Lite. Map -
//   0x00 CTRL [0]tx_en [1]rx_en [2]par_en [3]par_odd [4]stop2 [5]loopback
//   [7:6]bits(0=8,1=7,2=6,3=5); 0x04 FCW; 0x08 STATUS [0]tx_busy
//   [1]rx_busy [2]rx_avail [8]frame_err [9]parity_err [10]overrun (W1C)
//   [30:16]rx level; 0x0C error frame count. Version 1.0.0. Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (ip_axil_regs, registered read path). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-09-29
module uart_top #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 115_200,    // default baud rate
  parameter int FIFO_DEPTH = 512         // power of two
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
  // AXI4-Stream slave: bytes to transmit
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: received bytes
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // Serial pins
  output logic        uart_txd_o,
  input  logic        uart_rxd_i
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (CLK_HZ < 1 || BAUD < 1 || BAUD * 16 > CLK_HZ / 2) begin : g_chk_rate $error("%m: need BAUD*16 <= CLK_HZ/2"); end
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

  localparam int PHASE_W = 32;
  localparam logic [63:0] FCW64 =
      ((64'(BAUD) * 64'd16 << PHASE_W) + (64'(CLK_HZ) >> 1)) / 64'(CLK_HZ);
  localparam logic [4*32-1:0] RSTV = {32'd0, 32'd0, FCW64[31:0], 32'h0000_0003};
  localparam int LW = $clog2(FIFO_DEPTH) + 2;

  // ---- Register file ----
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

  wire       tx_en     = regs[0];
  wire       rx_en     = regs[1];
  wire       par_en    = regs[2];
  wire       par_odd   = regs[3];
  wire       stop2     = regs[4];
  wire       loopback  = regs[5];
  wire [3:0] data_bits = 4'd8 - {2'b00, regs[7:6]};

  // ---- Baud generator ----
  logic tick16;
  uart_baud #(.PHASE_W(PHASE_W)) u_baud (
    .clk(aclk), .rst_n(aresetn), .fcw(regs[32 +: PHASE_W]), .tick16_o(tick16));

  // ---- Transmit path: FIFO -> tx engine ----
  logic [7:0] txf_data; logic txf_valid, txf_ready, txf_last, txf_user;
  logic [LW-1:0] txf_level;
  logic txd, tx_busy;
  ip_axis_fifo #(.DATA_W(8), .DEPTH(FIFO_DEPTH)) u_txf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(s_axis_tdata), .s_tlast(s_axis_tlast), .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(txf_data), .m_tlast(txf_last), .m_tuser(txf_user),
    .m_tvalid(txf_valid), .m_tready(txf_ready), .level_o(txf_level));

  uart_tx u_tx (
    .clk(aclk), .rst_n(aresetn), .tick16_i(tick16), .en_i(tx_en),
    .data_bits_i(data_bits), .parity_en_i(par_en), .parity_odd_i(par_odd),
    .stop2_i(stop2), .s_tdata(txf_data), .s_tvalid(txf_valid),
    .s_tready(txf_ready), .txd_o(txd), .busy_o(tx_busy));
  assign uart_txd_o = txd;

  // ---- Receive path: rx engine -> FIFO ----
  logic [7:0] rx_data; logic rx_valid, rx_ferr, rx_perr, rx_busy;
  logic rxf_ready, rxf_last, rxf_user;
  logic [LW-1:0] rxf_level;
  wire  rxd_in = loopback ? txd : uart_rxd_i;
  uart_rx u_rx (
    .clk(aclk), .rst_n(aresetn), .tick16_i(tick16), .en_i(rx_en),
    .data_bits_i(data_bits), .parity_en_i(par_en), .parity_odd_i(par_odd),
    .rxd_i(rxd_in), .data_o(rx_data), .valid_o(rx_valid),
    .frame_err_o(rx_ferr), .parity_err_o(rx_perr), .busy_o(rx_busy));

  ip_axis_fifo #(.DATA_W(8), .DEPTH(FIFO_DEPTH)) u_rxf (
    .clk(aclk), .rst_n(aresetn),
    .s_tdata(rx_data), .s_tlast(1'b0), .s_tuser(rx_ferr | rx_perr),
    .s_tvalid(rx_valid), .s_tready(rxf_ready),
    .m_tdata(m_axis_tdata), .m_tlast(rxf_last), .m_tuser(rxf_user),
    .m_tvalid(m_axis_tvalid), .m_tready(m_axis_tready), .level_o(rxf_level));
  assign m_axis_tlast = rxf_last;

  // ---- Sticky error flags (write 1 to clear) and error counter ----
  logic frame_err, parity_err, overrun;
  logic [31:0] err_cnt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      frame_err <= 1'b0; parity_err <= 1'b0; overrun <= 1'b0; err_cnt <= '0;
    end else begin
      if (rx_valid & rx_ferr) frame_err  <= 1'b1;
      if (rx_valid & rx_perr) parity_err <= 1'b1;
      if (rx_valid & ~rxf_ready) overrun <= 1'b1;        // word dropped
      if (rx_valid & (rx_ferr | rx_perr)) err_cnt <= err_cnt + 32'd1;
      if (wr_pulse[2]) begin                             // W1C
        if (wr_data[8])  frame_err  <= 1'b0;
        if (wr_data[9])  parity_err <= 1'b0;
        if (wr_data[10]) overrun    <= 1'b0;
      end
    end
  end

  wire [31:0] status = {1'b0, 15'(rxf_level), 5'd0, overrun, parity_err,
                        frame_err, 5'd0, m_axis_tvalid, rx_busy, tx_busy};
  assign rd = {err_cnt, status, regs[63:0]};
endmodule
