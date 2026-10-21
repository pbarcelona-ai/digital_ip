// ***************
// Filename: py_stream_port.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream data port logic with TX and RX FIFOs. Lets a
//   processor move words in and out of a streaming peripheral (UART, I2C,
//   SPI, SPI flash) with plain register reads and writes, either polled or
//   interrupt driven. Its registers come and go on the cfg_* / sts_* ports;
//   py_stream_port_top.sv is the block with its AXI4-Lite register map
//   (src/include/py_stream_port_regs.sv: ID "PORT" / VERSION / DATE at
//   0x00-0x08, then
//     0x10 TXDATA (W) [23:0] data [24] tlast; pushed into the TX FIFO, or
//          dropped with STATUS.tx_ovf set when the FIFO is full.
//     0x14 RXDATA (R) [23:0] data [24] tlast [31] valid; a read with
//          valid=1 pops the RX FIFO, valid=0 means it was empty.
//     0x18 STATUS [0] rx_valid (RX not empty) [1] tx_ready (TX not full)
//          [2] tx_ovf (W1C) [3] tx_empty [19:8] rx level [31:20] tx level
//     0x1C IRQ_EN [0] rx_valid [1] tx_ready [2] tx_empty).
//   irq_o is a level: high while an enabled condition holds, so an RX
//   handler reads RXDATA until valid=0. Levels count every stored word,
//   including the FIFO output registers, so they can reach DEPTH+2.
//   Clock - aclk only. Reset - synchronous aresetn (active low), FIFOs
//   empty. Latency - FIFO fall-through 2 clocks.
// Date: 2026-10-20
module py_stream_port #(
  parameter int DATA_W   = 8,              // <= 24
  parameter int TX_DEPTH = 16,             // power of two >= 2
  parameter int RX_DEPTH = 16              // power of two >= 2
) (
  input  logic              aclk,
  input  logic              aresetn,
  // AXI-Stream master: words to the peripheral's TX input
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.master m_axis,
  // AXI-Stream slave: words from the peripheral's RX output
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.slave s_axis,
  output logic              irq_o,
  // register ports
  // regs: py_stream_port_regs_if.core (src/include/py_stream_port_regs_if.sv)
  py_stream_port_regs_if.core regs
);
  assign m_axis.tkeep = '1;      // not used by this block
  assign m_axis.tuser = '0;      // not used by this block
  if (DATA_W < 1 || DATA_W > 24) begin : g_bad $error("py_stream_port: DATA_W must be 1..24"); end

  // ---------------- TX FIFO: register writes -> peripheral ----------------
  logic tx_push, tx_ready, tx_user;
  logic [$clog2(TX_DEPTH)+1:0] tx_level;
  assign tx_push = regs.cfg_txdata_wr;
  axis_if #(.DATA_W(DATA_W)) u_txf_s ();
  assign u_txf_s.tdata = regs.cfg_txdata[DATA_W-1:0];
  assign u_txf_s.tlast = regs.cfg_txdata[24];
  assign u_txf_s.tuser = 1'b0;
  assign u_txf_s.tvalid = tx_push;
  assign tx_ready = u_txf_s.tready;
  axis_if #(.DATA_W(DATA_W)) u_txf_m ();
  assign m_axis.tdata = u_txf_m.tdata;
  assign m_axis.tlast = u_txf_m.tlast;
  assign tx_user = u_txf_m.tuser;
  assign m_axis.tvalid = u_txf_m.tvalid;
  assign u_txf_m.tready = m_axis.tready;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(TX_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(u_txf_s),
    .m(u_txf_m),
    .level_o(tx_level)
  );

  // ---------------- RX FIFO: peripheral -> register reads ----------------
  axis_if #(.DATA_W(DATA_W), .USER_W(1)) rx ();
  logic [$clog2(RX_DEPTH)+1:0] rx_level;
  // the read pulse comes in the clock RXDATA is returned, so popping then is safe
  assign rx.tready = regs.cfg_rxdata_rd && rx.tvalid;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(RX_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s(s_axis),
    .m(rx),
    .level_o(rx_level)
  );

  logic tx_ovf;
  wire  [2:0] irq_en = regs.cfg_irq_en;
  wire  tx_empty = (tx_level == '0);
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      tx_ovf <= 1'b0;
    end
    else begin
      if (regs.cfg_status_wr && regs.cfg_status[2]) tx_ovf <= 1'b0;   // W1C first: a set in the same clock wins
      if (tx_push && !tx_ready) tx_ovf <= 1'b1;
    end
  end

  assign regs.sts_rxdata = {rx.tvalid, 6'd0, rx.tvalid & rx.tlast, 24'(rx.tvalid ? rx.tdata : '0)};
  assign regs.sts_status = {12'(tx_level), 12'(rx_level), 4'd0, tx_empty, tx_ovf, tx_ready, rx.tvalid};

  // not used: TXDATA bits above DATA_W (but tlast [24]), the STATUS bits that are not W1C, IRQ_EN's write
  // pulse (acts by value), the TX FIFO's tuser
  wire unused_ok = &{1'b0, regs.cfg_txdata, regs.cfg_status, regs.cfg_irq_en_wr, tx_user};

  always_ff @(posedge aclk) begin
    if (!aresetn) irq_o <= 1'b0;
    else          irq_o <= (irq_en[0] && rx.tvalid) || (irq_en[1] && tx_ready) || (irq_en[2] && tx_empty);
  end
endmodule
