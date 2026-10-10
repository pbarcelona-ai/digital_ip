// ***************
// Filename: axi4_lite_cdc_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the AXI-Lite clock domain
//   bridge. A 100 MHz AXI-Lite master (BFM) accesses a register file that
//   runs on an unrelated 37 MHz clock through the bridge. Tests
//   write/readback, byte strobes, back-to-back transactions, response
//   codes for out-of-range addresses and a random access soak. Prints TEST
//   PASSED on success.
//   The test tasks are in tests/axi4_lite_cdc_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module axi4_lite_cdc_tb;
  logic aclk = 0, mclk = 0, aresetn = 0, mresetn = 0;
  always #5.0 aclk = ~aclk;
  always #13.5 mclk = ~mclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [7:0] m_awaddr, m_araddr;
  logic m_awvalid, m_awready, m_wvalid, m_wready, m_bvalid, m_bready;
  logic m_arvalid, m_arready, m_rvalid, m_rready;
  logic [31:0] m_wdata, m_rdata;
  logic [3:0] m_wstrb;
  logic [1:0] m_bresp, m_rresp;
  axi4_lite_cdc #(.ADDR_W(8)) dut (
    .s_clk(aclk),
    .s_rst_n(aresetn),
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
    .m_clk(mclk),
    .m_rst_n(mresetn),
    .m_axil_awaddr(m_awaddr),
    .m_axil_awvalid(m_awvalid),
    .m_axil_awready(m_awready),
    .m_axil_wdata(m_wdata),
    .m_axil_wstrb(m_wstrb),
    .m_axil_wvalid(m_wvalid),
    .m_axil_wready(m_wready),
    .m_axil_bresp(m_bresp),
    .m_axil_bvalid(m_bvalid),
    .m_axil_bready(m_bready),
    .m_axil_araddr(m_araddr),
    .m_axil_arvalid(m_arvalid),
    .m_axil_arready(m_arready),
    .m_axil_rdata(m_rdata),
    .m_axil_rresp(m_rresp),
    .m_axil_rvalid(m_rvalid),
    .m_axil_rready(m_rready)
  );
  logic [8*32-1:0] regs;
  logic [7:0] wrp;
  logic [31:0] wrd;
  ip_axil_regs #(
    .ADDR_W(8),
    .NREG(8)
  ) slave (
    .aclk(mclk),
    .aresetn(mresetn),
    .s_axil_awaddr(m_awaddr),
    .s_axil_awvalid(m_awvalid),
    .s_axil_awready(m_awready),
    .s_axil_wdata(m_wdata),
    .s_axil_wstrb(m_wstrb),
    .s_axil_wvalid(m_wvalid),
    .s_axil_wready(m_wready),
    .s_axil_bresp(m_bresp),
    .s_axil_bvalid(m_bvalid),
    .s_axil_bready(m_bready),
    .s_axil_araddr(m_araddr),
    .s_axil_arvalid(m_arvalid),
    .s_axil_arready(m_arready),
    .s_axil_rdata(m_rdata),
    .s_axil_rresp(m_rresp),
    .s_axil_rvalid(m_rvalid),
    .s_axil_rready(m_rready),
    .reg_o(regs),
    .wr_pulse_o(wrp),
    .wr_data_o(wrd),
    .rd_i(regs)
  );
  int errors = 0;
  logic [31:0] rd;
  logic [31:0] model [0:7];
  // test tasks: tests/axi4_lite_cdc_tests.sv
  `include "axi4_lite_cdc_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axi4_lite_cdc_tb.vcd");
      $dumpvars(0, axi4_lite_cdc_tb);
    end
    repeat (5) @(posedge aclk);
    aresetn = 1;
    mresetn = 1;
    repeat (5) @(posedge aclk);
    for (int i = 0; i < 8; i++) model[i] = 0;
    // ---- Test 1: write then read every register ----
    for (int i = 0; i < 8; i++) begin
      bfm.write(i*4, 32'hA000_0000 + i*32'h1111);
      model[i] = 32'hA000_0000 + i*32'h1111;
    end
    for (int i = 0; i < 8; i++) begin
      bfm.read(i*4, rd);
      check(rd == model[i], $sformatf("reg %0d got %h", i, rd));
    end
    // ---- Test 2: byte strobes ----
    bfm.write_strb(8'h08, 32'hFFFF_FFFF, 4'b0101);
    model[2] = (model[2] & 32'hFF00_FF00) | 32'h00FF_00FF;
    bfm.read(8'h08, rd);
    check(rd == model[2], $sformatf("strobe result %h exp %h", rd, model[2]));
    // ---- Test 3: out of range address returns SLVERR through the bridge ----
    bfm.read(8'h80, rd);
    check(bfm.last_resp == 2'b10, "read SLVERR expected");
    bfm.write(8'h80, 32'h1);
    check(bfm.last_resp == 2'b10, "write SLVERR expected");
    bfm.resp_errors = 0;
    // ---- Test 4: random soak ----
    for (int n = 0; n < 200; n++) begin
      int r;
      r = $urandom_range(0, 7);
      if ($urandom_range(0, 1)) begin
        model[r] = $urandom;
        bfm.write(r*4, model[r]);
      end
      else begin
        bfm.read(r*4, rd);
        check(rd == model[r], $sformatf("soak reg %0d got %h exp %h", r, rd, model[r]));
      end
    end
    check(bfm.resp_errors == 0, "unexpected AXI errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
