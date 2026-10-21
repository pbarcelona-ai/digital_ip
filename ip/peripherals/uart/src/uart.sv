// ***************
// Filename: uart.sv
// Author: FPGA Cores 4 U
// Description: UART logic. Full duplex UART with a fractional baud
//   generator, transmit and receive FIFOs (block RAM for deep FIFOs) and
//   AXI-Stream data ports: s_axis carries bytes to transmit, m_axis
//   carries received bytes. Control and status on the cfg_* / sts_* ports;
//   uart_top.sv is the block with its AXI4-Lite register map
//   (src/include/uart_regs.sv: ID "UART" / VERSION / DATE at 0x00-0x08,
//   CTRL 0x10, FCW 0x14, STATUS 0x18, ERR_CNT 0x1C). Clock - single
//   clock aclk, every input is synchronous to it unless a two-flop
//   synchronizer is mentioned. Reset - synchronous active low aresetn,
//   registers take the documented reset values. Latency - AXI-Lite write
//   response and read data follow the request by about 2 to 3 clocks
//   (uart_regs, axi4_lite_slave). Timing - registered outputs, no
//   combinational path from the bus to the pins. Errors - out of range
//   AXI-Lite accesses return SLVERR; illegal parameter values stop
//   elaboration with an $error.
// Date: 2026-10-20
module uart #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int BAUD       = 115_200,    // default baud rate
  parameter int FIFO_DEPTH = 512         // power of two
) (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Stream slave: bytes to transmit
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.slave s_axis,
  // AXI4-Stream master: received bytes
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 8
  axis_if.master m_axis,
  // Serial pins (not named uart: sv2v would take uart.txd for this module's own txd)
  // pins: uart_if.dte (ip/shared/src/interfaces/uart_if.sv) {uart_txd_o=txd uart_rxd_i=rxd}
  uart_if.dte pins,
  // register ports
  // regs: uart_regs_if.core (src/include/uart_regs_if.sv)
  uart_regs_if.core regs
);
  assign m_axis.tkeep = '1;      // not used by this block
  assign m_axis.tuser = '0;      // not used by this block
  if (CLK_HZ < 1 || BAUD < 1 || BAUD * 16 > CLK_HZ / 2) begin : g_chk_rate $error("%m: need BAUD*16 <= CLK_HZ/2"); end
  if (FIFO_DEPTH < 2 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fd $error("%m: FIFO_DEPTH must be a power of two >= 2"); end

  localparam int LW = $clog2(FIFO_DEPTH) + 2;

  localparam int PHASE_W = 32;
  // ---- Registers (cfg_* / sts_* ports of uart_regs, joined in uart_top) ----
  wire [31:0] ctrl = regs.cfg_ctrl, fcw_r = regs.cfg_fcw, status_wd = regs.cfg_status;
  wire        status_wr = regs.cfg_status_wr;

  wire       tx_en     = ctrl[0];
  wire       rx_en     = ctrl[1];
  wire       par_en    = ctrl[2];
  wire       par_odd   = ctrl[3];
  wire       stop2     = ctrl[4];
  wire       loopback  = ctrl[5];
  wire [3:0] data_bits = 4'd8 - {2'b00, ctrl[7:6]};

  // ---- Baud generator ----
  logic tick16;
  uart_baud #(.PHASE_W(PHASE_W)) u_baud (
    .clk(aclk),
    .rst_n(aresetn),
    .fcw(fcw_r[PHASE_W-1:0]),
    .tick16_o(tick16)
  );

  // ---- Transmit path: FIFO -> tx engine ----
  axis_if #(.DATA_W(8), .USER_W(1)) txf ();
  logic [LW-1:0] txf_level;
  logic txd, tx_busy;
  ip_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(s_axis),
    .m(txf),
    .level_o(txf_level)
  );

  uart_tx u_tx (
    .clk(aclk),
    .rst_n(aresetn),
    .tick16_i(tick16),
    .en_i(tx_en),
    .data_bits_i(data_bits),
    .parity_en_i(par_en),
    .parity_odd_i(par_odd),
    .stop2_i(stop2),
    .s(txf),
    .txd_o(txd),
    .busy_o(tx_busy)
  );
  assign pins.txd = txd;

  // ---- Receive path: rx engine -> FIFO ----
  logic [7:0] rx_data;
  logic rx_valid, rx_ferr, rx_perr, rx_busy;
  logic rxf_ready, rxf_last, rxf_user;
  logic [LW-1:0] rxf_level;
  wire  rxd_in = loopback ? txd : pins.rxd;
  uart_rx u_rx (
    .clk(aclk),
    .rst_n(aresetn),
    .tick16_i(tick16),
    .en_i(rx_en),
    .data_bits_i(data_bits),
    .parity_en_i(par_en),
    .parity_odd_i(par_odd),
    .rxd_i(rxd_in),
    .data_o(rx_data),
    .valid_o(rx_valid),
    .frame_err_o(rx_ferr),
    .parity_err_o(rx_perr),
    .busy_o(rx_busy)
  );

  axis_if #(.DATA_W(8)) u_rxf_s ();
  assign u_rxf_s.tdata = rx_data;
  assign u_rxf_s.tlast = 1'b0;
  assign u_rxf_s.tuser = rx_ferr | rx_perr;
  assign u_rxf_s.tvalid = rx_valid;
  assign rxf_ready = u_rxf_s.tready;
  axis_if #(.DATA_W(8)) u_rxf_m ();
  assign m_axis.tdata = u_rxf_m.tdata;
  assign rxf_last = u_rxf_m.tlast;
  assign rxf_user = u_rxf_m.tuser;
  assign m_axis.tvalid = u_rxf_m.tvalid;
  assign u_rxf_m.tready = m_axis.tready;
  ip_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(u_rxf_s),
    .m(u_rxf_m),
    .level_o(rxf_level)
  );
  assign m_axis.tlast = rxf_last;

  // ---- Sticky error flags (write 1 to clear) and error counter ----
  logic frame_err, parity_err, overrun;
  logic [31:0] err_cnt;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      frame_err <= 1'b0;
      parity_err <= 1'b0;
      overrun <= 1'b0;
      err_cnt <= '0;
    end else begin
      if (status_wr) begin                               // W1C first: a set in the same clock wins
        if (status_wd[8])  frame_err  <= 1'b0;
        if (status_wd[9])  parity_err <= 1'b0;
        if (status_wd[10]) overrun    <= 1'b0;
      end
      if (rx_valid & rx_ferr) frame_err  <= 1'b1;
      if (rx_valid & rx_perr) parity_err <= 1'b1;
      if (rx_valid & ~rxf_ready) overrun <= 1'b1;        // word dropped
      if (rx_valid & (rx_ferr | rx_perr)) err_cnt <= err_cnt + 32'd1;
    end
  end

  assign regs.sts_status = {1'b0, 15'(rxf_level), 5'd0, overrun, parity_err,
                       frame_err, 5'd0, m_axis.tvalid, rx_busy, tx_busy};
  assign regs.sts_err_cnt = err_cnt;

  // not used: write pulses of registers acting by value, CTRL bits above [7:0], STATUS bits that are not
  // W1C flags, the TX FIFO's level, the RX FIFO's tuser (errors are flagged when the word arrives)
  wire unused_ok = &{1'b0, regs.cfg_ctrl_wr, regs.cfg_fcw_wr, ctrl[31:8], status_wd[31:11], status_wd[7:0],
                     txf_level, rxf_user};
endmodule
