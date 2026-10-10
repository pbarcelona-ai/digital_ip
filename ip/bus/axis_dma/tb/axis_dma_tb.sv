// ***************
// Filename: axis_dma_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the AXI-Stream DMA. MM2S
//   streams memory contents (data and tlast checked), S2MM stores a random
//   stream into memory (all words and surrounding memory checked), both
//   crossing 4 KB boundaries with random memory and stream stalls,
//   followed by a simultaneous MM2S to S2MM loopback copy. Prints TEST
//   PASSED on success.
//   The test tasks are in tests/axis_dma_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module axis_dma_tb;
  logic aclk = 0, aresetn = 0;
  always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [31:0] awaddr, wdata, araddr, rdata;
  logic [7:0] awlen, arlen;
  logic [2:0] awsize, arsize;
  logic [1:0] awburst, arburst, bresp, rresp;
  logic awvalid, awready, wvalid, wready, wlast, bvalid, bready;
  logic arvalid, arready, rlast, rvalid, rready;
  logic [3:0] wstrb;
  logic irq;
  logic [31:0] m_tdata, s_tdata, tb_tdata;
  logic m_tvalid, m_tready, m_tlast, s_tvalid, s_tready, s_tlast;
  logic tb_tvalid, tb_tlast;
  logic loop = 0;
  axis_dma #(
    .MAX_BURST(16),
    .FIFO_DEPTH(32)
  ) dut (
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
    .m_axi_awaddr(awaddr),
    .m_axi_awlen(awlen),
    .m_axi_awsize(awsize),
    .m_axi_awburst(awburst),
    .m_axi_awvalid(awvalid),
    .m_axi_awready(awready),
    .m_axi_wdata(wdata),
    .m_axi_wstrb(wstrb),
    .m_axi_wlast(wlast),
    .m_axi_wvalid(wvalid),
    .m_axi_wready(wready),
    .m_axi_bresp(bresp),
    .m_axi_bvalid(bvalid),
    .m_axi_bready(bready),
    .m_axi_araddr(araddr),
    .m_axi_arlen(arlen),
    .m_axi_arsize(arsize),
    .m_axi_arburst(arburst),
    .m_axi_arvalid(arvalid),
    .m_axi_arready(arready),
    .m_axi_rdata(rdata),
    .m_axi_rresp(rresp),
    .m_axi_rlast(rlast),
    .m_axi_rvalid(rvalid),
    .m_axi_rready(rready),
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast),
    .s_axis_tdata(s_tdata),
    .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready),
    .s_axis_tlast(s_tlast),
    .irq_o(irq)
  );
  axi4_mem_model #(
    .WORDS(4096),
    .STALL(30)
  ) mem (
    .aclk,
    .aresetn,
    .awaddr,
    .awlen,
    .awvalid,
    .awready,
    .wdata,
    .wstrb,
    .wlast,
    .wvalid,
    .wready,
    .bresp,
    .bvalid,
    .bready,
    .araddr,
    .arlen,
    .arvalid,
    .arready,
    .rdata,
    .rresp,
    .rlast,
    .rvalid,
    .rready
  );
  // Stream source mux: testbench source or MM2S loopback
  wire lb_ready;
  assign s_tdata  = loop ? m_tdata  : tb_tdata;
  assign s_tvalid = loop ? m_tvalid : tb_tvalid;
  assign s_tlast  = loop ? m_tlast  : tb_tlast;
  logic tb_ready;
  assign tb_ready = s_tready;
  // MM2S sink: random back pressure; in loopback mode ready comes from S2MM
  logic m_rnd = 1;
  always @(posedge aclk) m_rnd <= ($urandom_range(0, 9) < 7);
  assign m_tready = loop ? s_tready : m_rnd;

  int errors = 0;
  logic [31:0] rd;
  logic [31:0] cap[$];
  bit caplast[$];
  always @(posedge aclk) if (!loop && m_tvalid && m_tready) begin
    cap.push_back(m_tdata);
    caplast.push_back(m_tlast);
  end
  // test tasks: tests/axis_dma_tests.sv
  `include "axis_dma_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axis_dma_tb.vcd");
      $dumpvars(0, axis_dma_tb);
    end
    tb_tvalid = 0;
    tb_tdata = 0;
    tb_tlast = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    for (int i = 0; i < 4096; i++) mem.mem[i] = (i < 1024) ? $urandom : 32'hFFFF_FFFF;
    // ---- Test 1: MM2S 200 words starting 0xF80 (crosses 4 KB) ----
    bfm.write(8'h04, 32'h0F80);
    bfm.write(8'h08, 32'd800);
    bfm.write(8'h00, 32'h1);
    wait_done(8);
    check(cap.size() == 200, $sformatf("mm2s words %0d", cap.size()));
    for (int i = 0; i < cap.size(); i++) begin
      check(cap[i] === mem.mem[32'h0F80/4 + i], $sformatf("mm2s word %0d", i));
      check(caplast[i] == (i == 199), $sformatf("mm2s tlast at %0d", i));
    end
    // ---- Test 2: S2MM 150 words to 0x2FC0 (crosses 4 KB) ----
    begin
      logic [31:0] exp_q[$];
      exp_q.delete();
      bfm.write(8'h0C, 32'h2FC0);
      bfm.write(8'h10, 32'd600);
      bfm.write(8'h00, 32'h2);
      for (int i = 0; i < 150; i++) begin
        @(posedge aclk);
        #1;
        tb_tdata = $urandom;
        tb_tvalid = 1;
        tb_tlast = (i == 149);
        exp_q.push_back(tb_tdata);
        while (!tb_ready) begin
          @(posedge aclk);
          #1;
        end
        if ($urandom_range(0, 3) == 0) begin
          @(posedge aclk);
          #1 tb_tvalid = 0;
          repeat ($urandom_range(1, 4)) @(posedge aclk);
        end
      end
      @(posedge aclk);
      #1 tb_tvalid = 0;
      wait_done(9);
      for (int i = 0; i < 150; i++) check(mem.mem[32'h2FC0/4 + i] === exp_q[i], $sformatf("s2mm word %0d", i));
      check(mem.mem[32'h2FC0/4 - 1] === 32'hFFFF_FFFF && mem.mem[32'h2FC0/4 + 150] === 32'hFFFF_FFFF, "s2mm outside region");
    end
    // ---- Test 3: loopback MM2S -> S2MM (memory to memory through the streams) ----
    loop = 1;
    bfm.write(8'h04, 32'h0100);
    bfm.write(8'h08, 32'd256);
    bfm.write(8'h0C, 32'h2400);
    bfm.write(8'h10, 32'd256);
    bfm.write(8'h00, 32'h3);
    do bfm.read(8'h14, rd);
    while (rd[9] == 0);
    for (int i = 0; i < 64; i++) check(mem.mem[32'h2400/4 + i] === mem.mem[32'h0100/4 + i], $sformatf("loop word %0d", i));
    check(mem.mem[32'h2400/4 + 64] === 32'hFFFF_FFFF, "loop overrun");
    check(rd[11:10] == 0, "error flags set");
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #30_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
