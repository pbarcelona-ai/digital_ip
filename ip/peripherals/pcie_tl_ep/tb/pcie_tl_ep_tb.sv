// ***************
// Filename: pcie_tl_ep_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the PCIe transaction layer
//   endpoint. The testbench acts as a root complex driving 64 bit TLP
//   streams - configuration reads and writes (IDs, BAR0 sizing, completer
//   ID, command), memory writes and reads of BAR0 RAM with byte enables
//   and 3DW/4DW headers, the BAR0 stream window, UR completions for bad
//   addresses and unsupported types, and device to host DMA memory writes.
//   Prints TEST PASSED on success. Use +vcd for sim/pcie_tl_ep_tb.vcd.
//   The test tasks are in tests/pcie_tl_ep_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module pcie_tl_ep_tb;
  localparam real CLK_PERIOD = 10.0;         // 100 MHz
  localparam logic [31:0] BAR_BASE = 32'hA000_0000;
  localparam logic [15:0] HOST_ID  = 16'h00A0;

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr; logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [63:0] rx_d, tx_d; logic [7:0] rx_k, tx_k;
  logic rx_l = 0, rx_v = 0, rx_r, tx_l, tx_v, tx_r = 1;
  logic [31:0] s_d = 0, m_d; logic s_v = 0, s_r, s_l = 0, m_v, m_r = 1, m_l;

  pcie_tl_ep_top #(.FIFO_DEPTH(16)) dut (
    .aclk, .aresetn,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
    .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .rx_axis_tdata(rx_d), .rx_axis_tkeep(rx_k), .rx_axis_tlast(rx_l),
    .rx_axis_tvalid(rx_v), .rx_axis_tready(rx_r),
    .tx_axis_tdata(tx_d), .tx_axis_tkeep(tx_k), .tx_axis_tlast(tx_l),
    .tx_axis_tvalid(tx_v), .tx_axis_tready(tx_r),
    .s_axis_tdata(s_d), .s_axis_tvalid(s_v), .s_axis_tready(s_r), .s_axis_tlast(s_l),
    .m_axis_tdata(m_d), .m_axis_tvalid(m_v), .m_axis_tready(m_r), .m_axis_tlast(m_l));

  int errors = 0;

  // ------------------------------------------------------------
  // TLP builder: fill tlp[] then send_tlp() packs 2 DWs per beat
  // ------------------------------------------------------------
  logic [31:0] tlp [0:63];
  int          tlp_n;
  function automatic logic [31:0] dw0(input logic [2:0] fmt, input logic [4:0] t,
                                      input int len);
    return {fmt, t, 1'b0, 3'b000, 4'b0000, 1'b0, 1'b0, 2'b00, 2'b00, 10'(len)};
  endfunction

  // ------------------------------------------------------------
  // Transmit capture (random back pressure), packet extraction
  // ------------------------------------------------------------
  logic [31:0] tx_flat [$];
  int          tx_len  [$];
  int          cur_len = 0, pkts_read = 0, rd_off = 0;
  always @(posedge aclk) tx_r <= ($urandom_range(0, 9) < 8);
  always @(posedge aclk) if (tx_v && tx_r) begin
    tx_flat.push_back(tx_d[31:0]); cur_len++;
    if (tx_k[4]) begin tx_flat.push_back(tx_d[63:32]); cur_len++; end
    if (tx_l) begin tx_len.push_back(cur_len); cur_len = 0; end
  end

  logic [31:0] rp [0:63];
  int          rp_n;

  // test tasks: tests/pcie_tl_ep_tests.sv
  `include "pcie_tl_ep_tests.sv"

  // Stream window capture
  logic [31:0] str_q [$]; bit str_l_q [$];
  always @(posedge aclk) if (m_v && m_r) begin str_q.push_back(m_d); str_l_q.push_back(m_l); end

  logic [31:0] rd;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/pcie_tl_ep_tb.vcd"); $dumpvars(0, pcie_tl_ep_tb);
    end
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; rx_d = 0; rx_k = 0;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (3) @(posedge aclk);

    // ---- T1: CfgRd0 of the ID register ----
    cfg_tlp(0, 0, 8'h11, 0); wait_pkt();
    check_cpl(1, 1, 3'b000, 8'h11, 12'd4, 7'd0, "CfgRd0 id");
    check(rp_n == 4 && rp[3] == 32'h5678_1234, $sformatf("ID data %h", rp[3]));
    check(rp[1][31:16] == 16'h0100, "completer ID not captured from config request");

    // ---- T2: BAR0 sizing ----
    cfg_tlp(1, 4, 8'h12, 32'hFFFF_FFFF); wait_pkt();
    check_cpl(0, 0, 3'b000, 8'h12, 12'd4, 7'd0, "CfgWr0 bar");
    cfg_tlp(0, 4, 8'h13, 0); wait_pkt();
    check(rp_n == 4 && rp[3] == 32'hFFFF_E000, $sformatf("BAR0 size probe %h", rp[3]));

    // ---- T3: program BAR0 and command (mem + bus master) ----
    cfg_tlp(1, 4, 8'h14, BAR_BASE); wait_pkt();
    cfg_tlp(0, 4, 8'h15, 0); wait_pkt();
    check(rp[3] == BAR_BASE, "BAR0 readback");
    cfg_tlp(1, 1, 8'h16, 32'h0000_0006); wait_pkt();
    cfg_tlp(0, 1, 8'h17, 0); wait_pkt();
    check(rp[3][15:0] == 16'h0006, "command readback");
    axil_read(8'h10, rd); check(rd[1:0] == 2'b11, "STATUS mem_en/bus_master");
    axil_read(8'h18, rd); check(rd == BAR_BASE, "BAR0 register");

    // ---- T4: memory write then read, 3DW headers ----
    mem_wr(BAR_BASE + 32'h10, 4, 0, 4'hF, 4'hF, 8'h20, 32'h11);
    no_pkt("posted write");
    mem_rd(BAR_BASE + 32'h10, 4, 0, 4'hF, 4'hF, 8'h21); wait_pkt();
    check_cpl(1, 4, 3'b000, 8'h21, 12'd16, 7'h10, "MRd 4DW");
    check(rp_n == 7 && rp[3] == 32'h11 && rp[4] == 32'h12 && rp[5] == 32'h13 &&
          rp[6] == 32'h14, "MRd data mismatch");

    // ---- T5: byte enables (bytes 0 and 2 written) ----
    mem_wr(BAR_BASE + 32'h10, 1, 0, 4'b0101, 4'b0000, 8'h22, 32'hAABB_CCDD);
    mem_rd(BAR_BASE + 32'h10, 1, 0, 4'hF, 4'h0, 8'h23); wait_pkt();
    check(rp_n == 4 && rp[3] == 32'h00BB_00DD, $sformatf("byte enable merge %h", rp[3]));

    // ---- T6: 4DW header memory read ----
    mem_rd(BAR_BASE + 32'h14, 3, 1, 4'hF, 4'hF, 8'h24); wait_pkt();
    check_cpl(1, 3, 3'b000, 8'h24, 12'd12, 7'h14, "MRd 4DW header");
    check(rp[3] == 32'h12 && rp[4] == 32'h13 && rp[5] == 32'h14, "4DW MRd data");

    // ---- T7: partial byte enables shrink the byte count ----
    mem_rd(BAR_BASE + 32'h14, 2, 0, 4'b1100, 4'b0011, 8'h25); wait_pkt();
    check_cpl(1, 2, 3'b000, 8'h25, 12'd4, 7'h16, "MRd partial BE");

    // ---- T8: stream window (upper BAR half) ----
    mem_wr(BAR_BASE + 32'h1000, 5, 0, 4'hF, 4'hF, 8'h26, 32'hC0DE_0000);
    repeat (40) @(posedge aclk);
    check(str_q.size() == 5, $sformatf("stream window got %0d words", str_q.size()));
    if (str_q.size() == 5) begin
      for (int i = 0; i < 5; i++) check(str_q[i] == 32'hC0DE_0000 + i, "stream data");
      check(str_l_q[4] == 1 && str_l_q[0] == 0, "stream tlast on the last word only");
    end

    // ---- T9: unsupported request handling ----
    mem_rd(32'hB000_0000, 1, 0, 4'hF, 4'h0, 8'h27); wait_pkt();
    check_cpl(0, 0, 3'b001, 8'h27, 12'd4, 7'd0, "UR for bad address");
    mem_wr(32'hB000_0000, 2, 0, 4'hF, 4'hF, 8'h28, 32'h0);
    no_pkt("posted write to bad address");
    tlp[0] = dw0(3'b000, 5'b00010, 1); tlp[1] = {HOST_ID, 8'h29, 4'h0, 4'hF};
    tlp[2] = 32'h100; tlp_n = 3; send_tlp(); wait_pkt();        // I/O read
    check_cpl(0, 0, 3'b001, 8'h29, 12'd4, 7'd0, "UR for I/O read");
    mem_rd(BAR_BASE + 32'h10, 1, 0, 4'hF, 4'h0, 8'h2A); wait_pkt();  // still alive
    check(rp[3] == 32'h00BB_00DD, "endpoint recovered after UR");

    // ---- T10: DMA memory writes to host (3DW then 4DW header) ----
    axil_write(8'h04, 32'h1234_5000); axil_write(8'h08, 32'h0);
    axil_write(8'h0C, 32'd4);
    axil_write(8'h00, 32'h1);
    for (int i = 0; i < 8; i++) begin
      @(posedge aclk); #1 s_d = 32'hD0D0_0000 + i; s_v = 1; s_l = (i == 7);
      wait (s_r); @(posedge aclk); #1 s_v = 0; s_l = 0;
    end
    wait_pkt();
    check(rp_n == 7 && rp[0] == dw0(3'b010, 5'b00000, 4), "DMA TLP0 header");
    check(rp[1] == {16'h0100, 8'h00, 4'hF, 4'hF}, $sformatf("DMA TLP0 dw1 %h", rp[1]));
    check(rp[2] == 32'h1234_5000, "DMA TLP0 address");
    for (int i = 0; i < 4; i++) check(rp[3+i] == 32'hD0D0_0000 + i, "DMA TLP0 data");
    wait_pkt();
    check(rp_n == 7 && rp[2] == 32'h1234_5010 && rp[1][15:8] == 8'h01, "DMA TLP1 address/tag");
    for (int i = 0; i < 4; i++) check(rp[3+i] == 32'hD0D0_0004 + i, "DMA TLP1 data");
    axil_write(8'h00, 32'h0);
    axil_write(8'h04, 32'h0000_0100); axil_write(8'h08, 32'h0000_0001);  // > 4 GB
    axil_write(8'h0C, 32'd1);
    axil_write(8'h00, 32'h1);
    @(posedge aclk); #1 s_d = 32'hFEED_BEEF; s_v = 1; s_l = 1;
    wait (s_r); @(posedge aclk); #1 s_v = 0; s_l = 0;
    wait_pkt();
    check(rp_n == 5 && rp[0] == dw0(3'b011, 5'b00000, 1), "DMA 4DW header fmt");
    check(rp[1][7:0] == 8'h0F, "single DW write must use lastBE = 0 and firstBE = F");
    check(rp[2] == 32'h1 && rp[3] == 32'h100 && rp[4] == 32'hFEED_BEEF, "DMA 4DW address/data");
    axil_write(8'h00, 32'h0);

    // ---- T11: counters ----
    axil_read(8'h1C, rd); check(rd == 18, $sformatf("RX_TLP counter %0d", rd));
    axil_read(8'h20, rd); check(rd == 4, $sformatf("MWR counter %0d", rd));
    axil_read(8'h28, rd); check(rd == 7, $sformatf("CFG counter %0d", rd));
    axil_read(8'h2C, rd); check(rd == 2, $sformatf("UR counter %0d", rd));
    axil_read(8'h30, rd); check(rd == 3, $sformatf("DMA TLP counter %0d", rd));

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #3_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
