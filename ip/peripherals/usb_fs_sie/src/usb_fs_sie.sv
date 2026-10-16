// ***************
// Filename: usb_fs_sie.sv
// Author: FPGA Cores 4 U
// Description: USB 1.1 full-speed serial interface engine IP. Bit-level D+/D-
//   interface (NRZI, bit stuffing, SYNC, EOP, CRC5/CRC16, PID check, bus
//   reset detect) with AXI-Stream packet ports. m_axis delivers each received
//   packet as PID (low nibble), payload bytes (CRC16 removed), tlast on the
//   last byte and tuser=1 for packets with errors. s_axis takes packets to
//   send - byte 0 is the PID nibble, then payload; a complete packet must be
//   written before it is transmitted. No enumeration, endpoint or protocol
//   layer is included. Registers on the cfg_* / sts_* ports; usb_fs_sie_top.sv is
//   the block with its AXI4-Lite register map (src/include/usb_fs_sie_regs.sv:
//   ID "USBF" / VERSION / DATE at 0x00-0x08) - 0x10 CTRL [0]enable [1]D+
//   pull-up; 0x14 STATUS [0]bus_reset(W1C) [1]rx_overflow(W1C) [2]tx_busy
//   [3]rx_active [9:8]line D+/D-; 0x18 RX_GOOD; 0x1C RX_BAD; 0x20 TX_PKTS;
//   0x24 BIT_PERIOD (8.8 clocks). Scope - serial interface engine only (no
//   enumeration, endpoints or protocol stack). Clock - aclk, verified in
//   simulation at 48, 60 and 100 MHz only (BIT_PERIOD is an 8.8 fixed point
//   clocks-per-bit value; other frequencies are untested). Reset -
//   synchronous aresetn, D+/D- released, pull-up off, FIFOs empty. Latency -
//   a packet is sent a few bit times after it is complete in the transmit
//   FIFO, and a received packet appears on m_axis after the EOP and CRC
//   check. Errors - tuser on bad packets (CRC, PID check, stuff error),
//   RX_BAD counter, rx_overflow flag, bus_reset flag; illegal parameters stop
//   elaboration.
// Date: 2026-10-12
module usb_fs_sie #(
  parameter int CLK_HZ     = 100_000_000,
  parameter int FIFO_DEPTH = 512
) (

  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Stream slave: packets to transmit
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  input  logic        s_axis_tlast,
  // AXI4-Stream master: received packets
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  output logic        m_axis_tuser,
  // USB pins (full speed device / host style)
  input  logic        usb_dp_i,
  input  logic        usb_dm_i,
  output logic        usb_dp_o,
  output logic        usb_dm_o,
  output logic        usb_oe_o,          // 1 = drive the bus
  output logic        usb_pullup_o,       // D+ pull-up control (device)
  // register ports
  input  logic [1:0]  cfg_ctrl,          // CTRL
  input  logic [9:0]  cfg_status,        // STATUS: data written ...
  input  logic        cfg_status_wr,     // ... and its write pulse
  output logic [9:0]  sts_status,        // STATUS: value read
  output logic [31:0] sts_rx_good,       // RX_GOOD
  output logic [31:0] sts_rx_bad,        // RX_BAD
  output logic [31:0] sts_tx_pkts,       // TX_PKTS
  output logic [31:0] sts_bit_period     // BIT_PERIOD
);
  if (CLK_HZ < 24_000_000 || CLK_HZ > 400_000_000) begin : g_chk_clk $error("usb_fs_sie: CLK_HZ must be 24..400 MHz"); end
  if (FIFO_DEPTH < 4 || (FIFO_DEPTH & (FIFO_DEPTH - 1)) != 0) begin : g_chk_fifo $error("usb_fs_sie: FIFO_DEPTH must be a power of two >= 4"); end
  localparam logic [63:0] P64 = (64'(CLK_HZ) * 64'd256 + 64'd6_000_000) / 64'd12_000_000;
  localparam int LW = $clog2(FIFO_DEPTH) + 2;

  wire enable = cfg_ctrl[0];
  assign usb_pullup_o = cfg_ctrl[1];

  // ---- Receiver ----
  logic [7:0] rx_data;
  logic rx_valid, rx_last, rx_err;
  logic rx_active, rx_good, rx_bad, rx_reset, tx_busy;
  logic [1:0] line;
  usb_fs_rx #(.CLK_HZ(CLK_HZ)) u_rx (
    .clk(aclk),
    .rst_n(aresetn),
    .enable_i(enable & ~tx_busy),
    .dp_i(usb_dp_i),
    .dm_i(usb_dm_i),
    .data_o(rx_data),
    .valid_o(rx_valid),
    .last_o(rx_last),
    .err_o(rx_err),
    .active_o(rx_active),
    .good_o(rx_good),
    .bad_o(rx_bad),
    .reset_o(rx_reset),
    .line_o(line)
  );

  logic rxf_ready, rxf_user;
  logic [LW-1:0] rxf_lvl, txf_lvl;
  usb_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(rx_data),
    .s_tlast(rx_last),
    .s_tuser(rx_err),
    .s_tvalid(rx_valid),
    .s_tready(rxf_ready),
    .m_tdata(m_axis_tdata),
    .m_tlast(m_axis_tlast),
    .m_tuser(m_axis_tuser),
    .m_tvalid(m_axis_tvalid),
    .m_tready(m_axis_tready),
    .level_o(rxf_lvl)
  );

  // ---- Transmitter with whole-packet gating ----
  logic [7:0] tx_data;
  logic tx_valid, tx_last, tx_user, tx_pop;
  logic tx_done, txf_ready_unused;
  usb_axis_fifo #(
    .DATA_W(8),
    .DEPTH(FIFO_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(s_axis_tdata),
    .s_tlast(s_axis_tlast),
    .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid),
    .s_tready(s_axis_tready),
    .m_tdata(tx_data),
    .m_tlast(tx_last),
    .m_tuser(tx_user),
    .m_tvalid(tx_valid),
    .m_tready(tx_pop),
    .level_o(txf_lvl)
  );

  // Count complete packets in the TX FIFO (written tlast minus popped tlast)
  logic [15:0] pkts;
  wire  wr_last = s_axis_tvalid & s_axis_tready & s_axis_tlast;
  wire  rd_last = tx_valid & tx_pop & tx_last;
  always_ff @(posedge aclk) begin
    if (!aresetn) pkts <= '0;
    else          pkts <= pkts + {15'd0, wr_last} - {15'd0, rd_last};
  end

  usb_fs_tx #(.CLK_HZ(CLK_HZ)) u_tx (
    .clk(aclk),
    .rst_n(aresetn),
    .enable_i(enable),
    .bus_busy_i(rx_active),
    .s_data(tx_data),
    .s_valid(tx_valid),
    .s_last(tx_last),
    .pkt_avail_i(pkts != 16'd0),
    .s_ready(tx_pop),
    .dp_o(usb_dp_o),
    .dm_o(usb_dm_o),
    .oe_o(usb_oe_o),
    .busy_o(tx_busy),
    .pkt_done_o(tx_done)
  );

  // ---- Status flags and counters ----
  logic f_reset, f_ovf;
  logic [31:0] c_good, c_bad, c_tx;
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      f_reset <= 1'b0;
      f_ovf <= 1'b0;
      c_good <= '0;
      c_bad <= '0;
      c_tx <= '0;
    end else begin
      if (rx_reset) f_reset <= 1'b1;
      if (rx_valid & ~rxf_ready) f_ovf <= 1'b1;         // byte dropped
      if (rx_good) c_good <= c_good + 32'd1;
      if (rx_bad)  c_bad  <= c_bad  + 32'd1;
      if (tx_done) c_tx   <= c_tx   + 32'd1;
      if (cfg_status_wr) begin                          // W1C
        if (cfg_status[0]) f_reset <= 1'b0;
        if (cfg_status[1]) f_ovf   <= 1'b0;
      end
    end
  end

  assign sts_status = {line, 4'd0, rx_active, tx_busy, f_ovf, f_reset};
  assign sts_rx_good = c_good;
  assign sts_rx_bad = c_bad;
  assign sts_tx_pkts = c_tx;
  assign sts_bit_period = 32'(P64[23:0]);
endmodule
