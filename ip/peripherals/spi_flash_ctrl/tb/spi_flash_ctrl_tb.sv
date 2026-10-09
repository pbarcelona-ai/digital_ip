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
  spi_flash_ctrl dut (
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
  `include "spi_flash_ctrl_tests.sv"
  byte ref_mem [0:255];
  logic [7:0] st;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("spi_flash_ctrl_tb.vcd");
      $dumpvars(0, spi_flash_ctrl_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    check(cs_n == 1 && sclk == 0, "idle pins");
    bfm.read(8'h18, rd);
    check(rd == 32'h0001_0000, "version");
    // 1) JEDEC ID
    rxq.delete();
    last_seen = 0;
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF && rxq[1] == 8'h40 && rxq[2] == 8'h17 && last_seen, "JEDEC ID mismatch");
    bfm.read(8'h10, rd);
    check(rd[1] == 1 && rd[0] == 0, "done flag");
    bfm.write(8'h10, 32'h2);
    bfm.read(8'h10, rd);
    check(rd[1] == 0, "done W1C");
    // 2) write enable + status + page program
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    flash_status(st);
    check(st[1] == 1, "WEL not set");
    for (int i = 0; i < 40; i++) begin
      ref_mem[i] = $urandom;
      txq.push_back(ref_mem[i]);
    end
    cmd(8'h02, 1, 0, 0, 1, 24'h001210, 40);
    wait_idle();
    flash_status(st);
    check(st[0] == 1, "WIP after program");
    wait_wip();
    flash_status(st);
    check(st[1:0] == 0, "WEL/WIP after complete");
    // 3) read back with 03 and 0B
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 40);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 40, $sformatf("read size %0d", rxq.size()));
    for (int i = 0; i < 40 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i]) begin
      check(0, $sformatf("03 read byte %0d %h exp %h", i, rxq[i], ref_mem[i]));
      i = 40;
    end
    rxq.delete();
    cmd(8'h0B, 1, 1, 1, 0, 24'h001211, 30);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 30, "fast read size");
    for (int i = 0; i < 30 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i+1]) begin
      check(0, $sformatf("0B read byte %0d", i));
      i = 30;
    end
    // 4) read with back-pressure
    slow_rx = 1;
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 25);
    wait_idle();
    repeat (20) @(posedge aclk);
    slow_rx = 0;
    check(rxq.size() == 25, $sformatf("backpressure size %0d", rxq.size()));
    for (int i = 0; i < 25 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i]) begin
      check(0, $sformatf("bp byte %0d", i));
      i = 25;
    end
    // 5) sector erase
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    cmd(8'h20, 1, 0, 0, 0, 24'h001000, 0);
    wait_idle();
    wait_wip();
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 40);
    wait_idle();
    repeat (3) @(posedge aclk);
    begin
      bit allff;
      allff = 1;
      foreach (rxq[i]) if (rxq[i] !== 8'hFF) allff = 0;
      check(allff && rxq.size() == 40, "sector not erased");
    end
    // 6) program without write enable is ignored; slow source with page wrap
    for (int i = 0; i < 8; i++) txq.push_back(8'h11);
    cmd(8'h02, 1, 0, 0, 1, 24'h002000, 8);
    wait_idle();
    wait_wip();
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h002000, 8);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 8 && rxq[0] == 8'hFF, "program without WEL took effect");
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    slow_tx = 1;
    for (int i = 0; i < 20; i++) begin
      ref_mem[i] = i + 1;
      txq.push_back(8'(i + 1));
    end
    cmd(8'h02, 1, 0, 0, 1, 24'h0020F0, 20); // crosses the 256 byte page end -> wraps to 0x002000
    wait_idle();
    wait_wip();
    slow_tx = 0;
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h0020F0, 16);
    wait_idle();
    repeat (3) @(posedge aclk);
    for (int i = 0; i < 16; i++) check(rxq[i] === ref_mem[i], $sformatf("page tail byte %0d: %h", i, rxq[i]));
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h002000, 4);
    wait_idle();
    repeat (3) @(posedge aclk);
    for (int i = 0; i < 4; i++) check(rxq[i] === ref_mem[16 + i], $sformatf("page wrap byte %0d: %h exp %h", i, rxq[i], ref_mem[16+i]));
    // 7) command while busy is ignored, sets cmd_err
    rxq.delete(); // second command while busy
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    bfm.write(8'h00, 32'h0001_0005);
    wait_idle();
    bfm.read(8'h10, rd);
    check(rd[2] == 1, "cmd_err not set");
    check(rxq.size() == 3, "ignored command produced data");
    bfm.write(8'h10, 32'h6);
    bfm.read(8'h10, rd);
    check(rd[2:1] == 0, "flags not cleared");
    // 8) irq
    bfm.write(8'h14, 32'h1);
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    check(irq == 0, "irq early");
    wait_idle();
    repeat (2) @(posedge aclk);
    check(irq == 1, "irq not raised");
    bfm.write(8'h10, 32'h2);
    repeat (2) @(posedge aclk);
    check(irq == 0, "irq not cleared");
    // 9) faster clock
    bfm.write(8'h0C, 32'd3);
    rxq.delete();
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF, "ID at CLKDIV=3");
    bfm.write(8'h0C, 32'd1);
    rxq.delete();
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF, "CLKDIV below minimum not clamped");
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
