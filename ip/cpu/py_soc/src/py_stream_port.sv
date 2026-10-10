// ***************
// Filename: py_stream_port.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Lite to AXI-Stream data port with TX and RX FIFOs. Lets
//   a processor move words in and out of a streaming peripheral (UART, I2C,
//   SPI, SPI flash) with plain register reads and writes, either polled or
//   interrupt driven. Map -
//     0x00 TXDATA (W) [23:0] data [24] tlast; pushed into the TX FIFO, or
//          dropped with STATUS.tx_ovf set when the FIFO is full.
//     0x04 RXDATA (R) [23:0] data [24] tlast [31] valid; a read with
//          valid=1 pops the RX FIFO, valid=0 means it was empty.
//     0x08 STATUS [0] rx_valid (RX not empty) [1] tx_ready (TX not full)
//          [2] tx_ovf (W1C) [3] tx_empty [19:8] rx level [31:20] tx level
//     0x0C IRQ_EN [0] rx_valid [1] tx_ready [2] tx_empty
//   irq_o is a level: high while an enabled condition holds, so an RX
//   handler reads RXDATA until valid=0. Levels count every stored word,
//   including the FIFO output registers, so they can reach DEPTH+2.
//   Clock - aclk only. Reset - synchronous aresetn (active low), FIFOs
//   empty. Latency - register access through axi4_lite_slave, 2-3 clocks;
//   FIFO fall-through 2 clocks. Errors - accesses beyond 0x0C return
//   DECERR.
// Date: 2026-10-01
module py_stream_port #(
  parameter int DATA_W   = 8,              // <= 24
  parameter int TX_DEPTH = 16,             // power of two >= 2
  parameter int RX_DEPTH = 16              // power of two >= 2
) (
  input  logic              aclk,
  input  logic              aresetn,
  // AXI4-Lite slave
  input  logic [7:0]        s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [7:0]        s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
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
  output logic              irq_o
);
  if (DATA_W < 1 || DATA_W > 24) begin : g_bad $error("py_stream_port: DATA_W must be 1..24"); end

  logic       wr_en, rd_en;
  logic [7:0] wr_addr, rd_addr;
  logic [31:0] wr_data, rd_data;
  logic [3:0] wr_strb;
  axi4_lite_slave #(
    .ADDR_W(8),
    .READ_WAIT(1),
    .MAP_WORDS(4)
  ) u_slv (
    .aclk,
    .aresetn,
    .s_axil_awaddr,
    .s_axil_awvalid,
    .s_axil_awready,
    .s_axil_wdata,
    .s_axil_wstrb,
    .s_axil_wvalid,
    .s_axil_wready,
    .s_axil_bresp,
    .s_axil_bvalid,
    .s_axil_bready,
    .s_axil_araddr,
    .s_axil_arvalid,
    .s_axil_arready,
    .s_axil_rdata,
    .s_axil_rresp,
    .s_axil_rvalid,
    .s_axil_rready,
    .wr_en_o(wr_en),
    .wr_addr_o(wr_addr),
    .wr_data_o(wr_data),
    .wr_strb_o(wr_strb),
    .wr_err_i(1'b0),
    .rd_en_o(rd_en),
    .rd_addr_o(rd_addr),
    .rd_data_i(rd_data),
    .rd_valid_i(rd_en),
    .rd_err_i(1'b0)
  );

  // ---------------- TX FIFO: register writes -> peripheral ----------------
  logic tx_push, tx_ready, tx_user;
  logic [$clog2(TX_DEPTH)+1:0] tx_level;
  assign tx_push = wr_en && wr_addr[3:2] == 2'd0;
  ip_axis_fifo #(
    .DATA_W(DATA_W),
    .DEPTH(TX_DEPTH)
  ) u_txf (
    .clk(aclk),
    .rst_n(aresetn),
    .s_tdata(wr_data[DATA_W-1:0]),
    .s_tlast(wr_data[24]),
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
  // rd_data is sampled in the same clock as rd_en, so popping then is safe
  assign rx_pop = rd_en && rd_addr[3:2] == 2'd1 && rx_valid;
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
  logic [2:0] irq_en;
  wire  tx_empty = (tx_level == '0);
  always_ff @(posedge aclk) begin
    if (!aresetn) begin
      tx_ovf <= 1'b0;
      irq_en <= '0;
    end
    else begin
      if (tx_push && !tx_ready) tx_ovf <= 1'b1;
      if (wr_en && wr_addr[3:2] == 2'd2 && wr_data[2]) tx_ovf <= 1'b0;
      if (wr_en && wr_addr[3:2] == 2'd3) irq_en <= wr_data[2:0];
    end
  end

  always_comb begin
    case (rd_addr[3:2])
      2'd1:    rd_data = {rx_valid, 6'd0, rx_valid & rx_last, 24'(rx_valid ? rx_data : '0)};
      2'd2:    rd_data = {12'(tx_level), 12'(rx_level), 4'd0, tx_empty, tx_ovf, tx_ready, rx_valid};
      2'd3:    rd_data = {29'd0, irq_en};
      default: rd_data = '0;                  // TXDATA is write-only
    endcase
  end

  always_ff @(posedge aclk) begin
    if (!aresetn) irq_o <= 1'b0;
    else          irq_o <= (irq_en[0] && rx_valid) || (irq_en[1] && tx_ready) || (irq_en[2] && tx_empty);
  end
endmodule
