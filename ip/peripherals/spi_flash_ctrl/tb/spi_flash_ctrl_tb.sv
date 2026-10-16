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
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();
  axil_bfm #(.ADDR_W(8)) bfm (
    .*
  );
  axis_if #(.DATA_W(8)) m_axis ();
  initial m_axis.tready = 1;
  axis_if #(.DATA_W(8)) s_axis ();
  initial s_axis.tdata = 0;
  initial s_axis.tvalid = 0;
  spi_if #(.NUM_CS(1)) spi ();
  logic irq;
  int wipc;
  spi_flash_ctrl_top dut (
    .aclk,
    .aresetn,
    .s_axil(s_axil),
    .s_axis(s_axis),
    .m_axis(m_axis),
    .spi(spi),
    .irq_o(irq)
  );
  spi_flash_bfm flash (
    .sclk(spi.sclk),
    .cs_n(spi.cs_n),
    .mosi(spi.mosi),
    .miso(spi.miso),
    .wip_cycles(wipc)
  );
  int errors = 0;
  logic [31:0] rd;
  // receive collector
  byte rxq[$];
  bit last_seen = 0;
  int rx_gap = 0;
  always @(posedge aclk) begin
    if (rx_gap > 0 && m_axis.tvalid) begin m_axis.tready <= 0; end
    if (m_axis.tvalid && m_axis.tready) begin
      rxq.push_back(m_axis.tdata);
      if (m_axis.tlast) last_seen = 1;
    end
  end
  // slow rx consumer mode
  bit slow_rx = 0;
  int slow_cnt = 0;
  always @(posedge aclk)
    if (slow_rx) begin
      slow_cnt++;
      m_axis.tready <= (slow_cnt % 7 == 0);
    end else m_axis.tready <= 1;
  // transmit source
  byte txq[$];
  bit slow_tx = 0;
  int tx_cnt = 0;
  always @(posedge aclk) begin
    if (s_axis.tvalid && s_axis.tready) begin s_axis.tvalid <= 0; end
    if (!s_axis.tvalid || s_axis.tready) begin
      tx_cnt++;
      if (txq.size() > 0 && (!slow_tx || tx_cnt % 5 == 0) && !(s_axis.tvalid && !s_axis.tready)) begin
        s_axis.tdata <= txq.pop_front();
        s_axis.tvalid <= 1;
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
