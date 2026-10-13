// ***************
// Filename: spi_flash_ctrl_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for spi_flash_ctrl with a
//   behavioral SPI NOR flash model (JEDEC ID, 03/0B read, 06/04 write
//   enable, 02 page program with 256 byte page wrap and AND-only
//   programming, 20 sector erase, 05 status with WIP/WEL). Tests read ID,
//   page program plus status polling, normal and fast read back, sector
//   erase, a read with stream back-pressure, a write with a slow source, a
//   command issued while busy (ignored, cmd_err), the done flag / irq and
//   W1C, and the CLKDIV setting. Prints TEST PASSED on success.
//   The test tasks are in tests/spi_flash_ctrl_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module spi_flash_ctrl_tb;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  logic [7:0]  s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [7:0] txd = 0, rxd;
  logic txv = 0, txr, rxv, rxr = 1, rxl;
  logic sclk, cs_n, mosi, miso, irq;
  int wipc;
  spi_flash_ctrl_top dut (
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
    .s_axis_tdata(txd),
    .s_axis_tvalid(txv),
    .s_axis_tready(txr),
    .m_axis_tdata(rxd),
    .m_axis_tvalid(rxv),
    .m_axis_tready(rxr),
    .m_axis_tlast(rxl),
    .sclk_o(sclk),
    .cs_n_o(cs_n),
    .mosi_o(mosi),
    .miso_i(miso),
    .irq_o(irq)
  );
  spi_flash_bfm flash (
    .sclk,
    .cs_n,
    .mosi,
    .miso,
    .wip_cycles(wipc)
  );
  int errors = 0;
  logic [31:0] rd;
  // receive collector
  byte rxq[$];
  bit last_seen = 0;
  int rx_gap = 0;
  always @(posedge aclk) begin
    if (rx_gap > 0 && rxv) begin rxr <= 0; end
    if (rxv && rxr) begin
      rxq.push_back(rxd);
      if (rxl) last_seen = 1;
    end
  end
  // slow rx consumer mode
  bit slow_rx = 0;
  int slow_cnt = 0;
  always @(posedge aclk)
    if (slow_rx) begin
      slow_cnt++;
      rxr <= (slow_cnt % 7 == 0);
    end else rxr <= 1;
  // transmit source
  byte txq[$];
  bit slow_tx = 0;
  int tx_cnt = 0;
  always @(posedge aclk) begin
    if (txv && txr) begin txv <= 0; end
    if (!txv || txr) begin
      tx_cnt++;
      if (txq.size() > 0 && (!slow_tx || tx_cnt % 5 == 0) && !(txv && !txr)) begin
        txd <= txq.pop_front();
        txv <= 1;
      end
    end
  end
  // test tasks: tests/spi_flash_ctrl_tests.sv
  byte ref_mem [0:255];
  logic [7:0] st;
  `include "spi_flash_ctrl_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("spi_flash_ctrl_tb.vcd");
      $dumpvars(0, spi_flash_ctrl_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_idle();
    test_jedec_id();
    test_page_program();
    test_read();
    test_backpressure();
    test_sector_erase();
    test_no_wel();
    test_busy_cmd();
    test_irq();
    test_fast_clock();

    check(bfm.resp_errors == 0, "bus errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
