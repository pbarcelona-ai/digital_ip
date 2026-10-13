// ***************
// Filename: sdio_host_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sdio_host with a behavioral SD
//   card model (CMD0, CMD2 long response, CMD8, CMD13, CMD17 block read,
//   CMD24 block write, R3 response, four 512 byte blocks, 1-bit and 4-bit
//   buses, CRC7/CRC16 generation and checking). Tests command/response of
//   all types, block write then read back in 1-bit and 4-bit mode,
//   streamed data and tlast, corrupted response CRC, corrupted read data
//   CRC (block must be discarded), write CRC error status token, response
//   timeout, data timeout, buf_err cases (command while busy, write
//   without data, bad block size), interrupt output and the W1C status.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/sdio_host_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module sdio_host_tb;
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
  logic sd_clk, cmd_o, cmd_oe, irq;
  logic [3:0] dat_o, dat_oe;
  wire cmd_line;
  wire [3:0] dat_line;
  sdio_host_top #(.BUF_BYTES(512)) dut (
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
    .sd_clk_o(sd_clk),
    .cmd_o(cmd_o),
    .cmd_oe_o(cmd_oe),
    .cmd_i(cmd_line),
    .dat_o(dat_o),
    .dat_oe_o(dat_oe),
    .dat_i(dat_line),
    .irq_o(irq)
  );
  int errors = 0;
  logic [31:0] rd;
  // ---------------- SD card ----------------
  sdio_bfm card (
    .sd_clk,
    .cmd_o,
    .cmd_oe,
    .dat_o,
    .dat_oe,
    .cmd_line,
    .dat_line
  );
  // ---------------- stream collectors / sources ----------------
  byte rxq[$];
  int rx_last = 0;
  always @(posedge aclk) if (rxv && rxr) begin
    rxq.push_back(rxd);
    if (rxl) rx_last++;
  end
  byte src[512];
  logic [31:0] st;
  // test tasks: tests/sdio_host_tests.sv
  `include "sdio_host_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sdio_host_tb.vcd");
      $dumpvars(0, sdio_host_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_setup();
    test_commands();
    test_block_1bit();
    test_block_4bit();
    test_read_crc_err();
    test_write_crc_err();
    test_data_timeout();
    test_buf_err();
    test_irq();

    check(bfm.resp_errors == 0, "bus errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #60_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
