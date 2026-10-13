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

  logic [7:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [63:0] rx_d, tx_d;
  logic [7:0] rx_k, tx_k;
  logic rx_l, rx_v, rx_r, tx_l, tx_v, tx_r;
  logic [31:0] s_d = 0, m_d;
  logic s_v = 0, s_r, s_l = 0, m_v, m_r = 1, m_l;

  pcie_tl_ep_top #(.FIFO_DEPTH(16)) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr(awaddr),
    .s_axil_awvalid(awvalid),
    .s_axil_awready(awready),
    .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb),
    .s_axil_wvalid(wvalid),
    .s_axil_wready(wready),
    .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid),
    .s_axil_bready(bready),
    .s_axil_araddr(araddr),
    .s_axil_arvalid(arvalid),
    .s_axil_arready(arready),
    .s_axil_rdata(rdata),
    .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .rx_axis_tdata(rx_d),
    .rx_axis_tkeep(rx_k),
    .rx_axis_tlast(rx_l),
    .rx_axis_tvalid(rx_v),
    .rx_axis_tready(rx_r),
    .tx_axis_tdata(tx_d),
    .tx_axis_tkeep(tx_k),
    .tx_axis_tlast(tx_l),
    .tx_axis_tvalid(tx_v),
    .tx_axis_tready(tx_r),
    .s_axis_tdata(s_d),
    .s_axis_tvalid(s_v),
    .s_axis_tready(s_r),
    .s_axis_tlast(s_l),
    .m_axis_tdata(m_d),
    .m_axis_tvalid(m_v),
    .m_axis_tready(m_r),
    .m_axis_tlast(m_l)
  );

  int errors = 0;

  // ------------------------------------------------------------
  // PCIe root complex: TLP builder / sender, completion capture
  // ------------------------------------------------------------
  pcie_bfm #(.HOST_ID(HOST_ID)) pcie (
    .clk(aclk),
    .rx_d,
    .rx_k,
    .rx_l,
    .rx_v,
    .rx_r,
    .tx_d,
    .tx_k,
    .tx_l,
    .tx_v,
    .tx_r
  );
  int          pkts_read = 0, rd_off = 0;     // read position in the pcie_bfm capture queues

  logic [31:0] rp [0:63];
  int          rp_n;

  // test tasks: tests/pcie_tl_ep_tests.sv
  logic [7:0] reg_base = 8'h10;                   // the register map after the ID block
  logic [1:0] last_bresp;

  // Stream window capture
  logic [31:0] str_q [$];
  bit str_l_q [$];
  always @(posedge aclk) if (m_v && m_r) begin
    str_q.push_back(m_d);
    str_l_q.push_back(m_l);
  end

  logic [31:0] rd;
  `include "pcie_tl_ep_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/pcie_tl_ep_tb.vcd");
      $dumpvars(0, pcie_tl_ep_tb);
    end
    awvalid = 0;
    wvalid = 0;
    bready = 0;
    arvalid = 0;
    rready = 0;
    awaddr = 0;
    araddr = 0;
    wdata = 0;
    wstrb = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (3) @(posedge aclk);

    test_id_block();
    test_cfg_id();
    test_bar_sizing();
    test_bar_program();
    test_mem_rw();
    test_byte_enables();
    test_4dw_read();
    test_partial_be();
    test_stream_window();
    test_unsupported();
    test_dma();
    test_counters();

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #3_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
