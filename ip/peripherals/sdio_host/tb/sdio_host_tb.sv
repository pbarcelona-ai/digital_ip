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
  sdio_host #(.BUF_BYTES(512)) dut (
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
  // test tasks: tests/sdio_host_tests.sv
  `include "sdio_host_tests.sv"
  logic [31:0] st;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sdio_host_tb.vcd");
      $dumpvars(0, sdio_host_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.read(8'h2C, rd);
    check(rd == 32'h0001_0000, "version");
    set_bus(0);
    repeat (20) @(posedge aclk);
    // ---- commands and responses ----
    cmd(0, 0, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[1] && !st[7:2], $sformatf("CMD0 status %h", st));
    bfm.write(8'h18, 32'hFE);
    cmd(8, 1, 0, 0, 32'h1AA);
    wait_idle();
    bfm.read(8'h08, rd);
    bfm.read(8'h18, st);
    check(rd == 32'h1AA && st[1] && !st[4], $sformatf("CMD8 resp %h st %h", rd, st));
    bfm.write(8'h18, 32'hFE);
    cmd(41, 1, 0, 1, 32'h4000_0000);
    wait_idle();
    bfm.read(8'h08, rd);
    check(rd == 32'hC0FF8000, $sformatf("R3 resp %h", rd));
    bfm.write(8'h18, 32'hFE);
    cmd(2, 2, 0, 1, 0);
    wait_idle();
    begin
      logic [31:0] r0, r1, r2, r3;
      bfm.read(8'h08, r0);
      bfm.read(8'h0C, r1);
      bfm.read(8'h10, r2);
      bfm.read(8'h14, r3);
      check({r3, r2, r1, r0} == 128'hA1B2C3D4_E5F60718_293A4B5C_6D7E8F01, "R2 long response");
    end
    bfm.write(8'h18, 32'hFE);
    cmd(13, 1, 0, 0, 32'h10000);
    wait_idle();
    bfm.read(8'h08, rd);
    check(rd == 32'h0900, "R1 resp");
    bfm.write(8'h18, 32'hFE);
    // response timeout
    cmd(63, 1, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[3] && !st[1], $sformatf("timeout status %h", st));
    bfm.write(8'h18, 32'hFE);
    // response CRC error
    card.inj_resp_crc = 1;
    cmd(13, 1, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[4] && !st[1], $sformatf("resp crc status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.inj_resp_crc = 0;
    // ---- block write / read, 1-bit ----
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    bfm.write(8'h20, 512);
    feed(512);
    cmd(24, 1, 2, 0, 1);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3], $sformatf("write status %h", st));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512; i++) if (card.cmem[512 + i] !== src[i]) same = 0;
      check(same, "card memory after 1-bit write");
    end
    rxq.delete();
    rx_last = 0;
    cmd(17, 1, 1, 0, 1);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("1-bit read status %h bytes %0d last %0d", st, rxq.size(), rx_last));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0;
      check(same, "1-bit read data");
    end
    // ---- 4-bit ----
    set_bus(1);
    repeat (10) @(posedge aclk);
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    feed(512);
    cmd(24, 1, 2, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3], $sformatf("4-bit write status %h", st));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512; i++) if (card.cmem[1024 + i] !== src[i]) same = 0;
      check(same, "card memory after 4-bit write");
    end
    rxq.delete();
    rx_last = 0;
    cmd(17, 1, 1, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("4-bit read status %h bytes %0d", st, rxq.size()));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0;
      check(same, "4-bit read data");
    end
    // ---- read data CRC error ----
    card.inj_data_crc = 1;
    rxq.delete();
    cmd(17, 1, 1, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[5] && !st[2] && rxq.size() == 0, $sformatf("data crc error status %h bytes %0d", st, rxq.size()));
    bfm.write(8'h18, 32'hFE);
    card.inj_data_crc = 0;
    // ---- write CRC status error ----
    card.inj_wr_status = 1;
    feed(512);
    cmd(24, 1, 2, 0, 3);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[5], $sformatf("write crc status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.inj_wr_status = 0;
    // ---- data timeout ----
    bfm.write(8'h24, 300);
    card.no_data = 1;
    cmd(17, 1, 1, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[6] && !st[2], $sformatf("data timeout status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.no_data = 0;
    bfm.write(8'h24, 100000);
    // ---- buf_err cases ----
    cmd(24, 1, 2, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7] && card.ncmds > 0, "write without data must set buf_err");
    bfm.write(8'h18, 32'hFE);
    bfm.write(8'h20, 0);
    cmd(17, 1, 1, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7], "bad block size");
    bfm.write(8'h18, 32'hFE);
    bfm.write(8'h20, 512);
    cmd(13, 1, 0, 0, 0);
    bfm.write(8'h00, 32'h0000_004D);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7] && st[1], $sformatf("command while busy %h", st));
    bfm.write(8'h18, 32'hFE);
    // ---- irq ----
    bfm.write(8'h28, 32'h1);
    cmd(0, 0, 0, 0, 0);
    check(irq == 0, "irq early");
    wait_idle();
    repeat (2) @(posedge aclk);
    check(irq == 1, "irq");
    bfm.write(8'h18, 32'h2);
    repeat (2) @(posedge aclk);
    check(irq == 0, "irq clear");
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
