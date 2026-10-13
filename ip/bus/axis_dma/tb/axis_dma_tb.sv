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
  axis_dma_top #(
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
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_mm2s();
    test_s2mm();
    test_loopback();

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
