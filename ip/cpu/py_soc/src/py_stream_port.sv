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
// Date: 2026-10-12
module py_stream_port #(
  parameter int DATA_W   = 8,              // <= 24
  parameter int TX_DEPTH = 16,             // power of two >= 2
  parameter int RX_DEPTH = 16              // power of two >= 2
) (
  input  logic              aclk,
  input  logic              aresetn,
  // AXI-Stream master: words to the peripheral's TX input
  output logic [DATA_W-1:0] m_axis_tdata,
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,
  output logic              m_axis_tlast,
  // AXI-Stream slave: words from the peripheral's RX output
  input  logic [DATA_W-1:0] s_axis_tdata,
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,
  input  logic              s_axis_tlast,
  output logic              irq_o,
  // register ports
  input  logic [24:0]       cfg_txdata,    // TXDATA: data written ...
  input  logic              cfg_txdata_wr, // ... and its write pulse
  output logic [31:0]       sts_rxdata,    // RXDATA: value read ...
  input  logic              cfg_rxdata_rd, // ... and its read pulse (pop)
  input  logic [31:0]       cfg_status,    // STATUS: data written ...
  input  logic              cfg_status_wr, // ... and its write pulse
  output logic [31:0]       sts_status,    // STATUS: value read
  input  logic [2:0]        cfg_irq_en     // IRQ_EN
);
  if (DATA_W < 1 || DATA_W > 24) begin : g_bad $error("py_stream_port: DATA_W must be 1..24"); end

  // ---------------- TX FIFO: register writes -> peripheral ----------------
  logic tx_push, tx_ready, tx_user;
  logic [$clog2(TX_DEPTH)+1:0] tx_level;
  assign tx_push = cfg_txdata_wr;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(TX_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(cfg_txdata[DATA_W-1:0]),
    .s_tlast(cfg_txdata[24]),
    .s_tuser(1'b0),
    .s_tvalid(tx_push),
    .s_tready(tx_ready),
    .m_tdata(m_axis_tdata),
    .m_tlast(m_axis_tlast),
    .m_tuser(tx_user),
    .m_tvalid(m_axis_tvalid),
    .m_tready(m_axis_tready),
    .level_o(tx_level)
  );

  // ---------------- RX FIFO: peripheral -> register reads ----------------
  logic [DATA_W-1:0] rx_data;
  logic rx_valid, rx_last, rx_pop, rx_user;
  logic [$clog2(RX_DEPTH)+1:0] rx_level;
  // the read pulse comes in the clock RXDATA is returned, so popping then is safe
  assign rx_pop = cfg_rxdata_rd && rx_valid;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(RX_DEPTH)
  ) u_rxf (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(s_axis_tdata),
    .s_tlast(s_axis_tlast),
    .s_tuser(1'b0),
    .s_tvalid(s_axis_tvalid),
    .s_tready(s_axis_tready),
    .m_tdata(rx_data),
    .m_tlast(rx_last),
    .m_tuser(rx_user),
    .m_tvalid(rx_valid),
    .m_tready(rx_pop),
    .level_o(rx_level)
  );

  logic tx_ovf;
  wire  [2:0] irq_en = cfg_irq_en;
  wire  tx_empty = (tx_level == '0);
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      tx_ovf <= 1'b0;
    end
    else begin
      if (tx_push && !tx_ready) tx_ovf <= 1'b1;
      if (cfg_status_wr && cfg_status[2]) tx_ovf <= 1'b0;
    end
  end

  assign sts_rxdata = {rx_valid, 6'd0, rx_valid & rx_last, 24'(rx_valid ? rx_data : '0)};
  assign sts_status = {12'(tx_level), 12'(rx_level), 4'd0, tx_empty, tx_ovf, tx_ready, rx_valid};

  always_ff @(posedge aclk) begin
    if (!aresetn) irq_o <= 1'b0;
    else          irq_o <= (irq_en[0] && rx_valid) || (irq_en[1] && tx_ready) || (irq_en[2] && tx_empty);
  end
endmodule
