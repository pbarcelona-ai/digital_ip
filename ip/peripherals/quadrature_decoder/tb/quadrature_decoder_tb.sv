// ***************
// Filename: quadrature_decoder_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the quadrature decoder IP. An
//   encoder model drives A/B/index. Tests forward and reverse counting
//   (x4), glitch rejection by the filter, illegal double transition error
//   count, index latch and clear, position load and the velocity AXI-
//   Stream samples. Prints TEST PASSED on success.
//   The test tasks are in tests/quadrature_decoder_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module quadrature_decoder_tb;
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
  logic a, b, z;
  logic [31:0] m_tdata;
  logic m_tvalid, m_tready = 1, m_tlast;
  quad_dec_top dut (
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
    .enc_a_i(a),
    .enc_b_i(b),
    .enc_z_i(z),
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast)
  );
  // incremental encoder driving the DUT
  quad_bfm enc (
    .clk(aclk),
    .a,
    .b,
    .z
  );
  int errors = 0;
  logic [31:0] rd;
  // test tasks: tests/quadrature_decoder_tests.sv
  `include "quadrature_decoder_tests.sv"
  int vel_samples[$];
  always @(posedge aclk) if (m_tvalid && m_tready) vel_samples.push_back($signed(m_tdata));
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("quadrature_decoder_tb.vcd");
      $dumpvars(0, quadrature_decoder_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.write(8'h00, 32'h0301);                    // en, filter = 3 clocks
    bfm.write(8'h0C, 32'd400);                     // velocity window 400 clocks
    // ---- Test 1: 40 forward steps ----
    repeat (40) step(1, 12);
    repeat (8) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 40, $sformatf("position %0d exp 40", $signed(rd)));
    bfm.read(8'h10, rd);
    check(rd[0] == 1, "direction forward");
    // ---- Test 2: 15 reverse steps ----
    repeat (15) step(0, 12);
    repeat (8) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 25, $sformatf("position %0d exp 25", $signed(rd)));
    bfm.read(8'h10, rd);
    check(rd[0] == 0, "direction reverse");
    // ---- Test 3: short glitch on A (1 clock) must be filtered ----
    enc.glitch_a(1);
    repeat (10) @(posedge aclk);
    bfm.read(8'h04, rd);
    check($signed(rd) == 25, "glitch changed position");
    // ---- Test 4: illegal jump (both bits change) ----
    enc.jump(2'b11, 10);
    bfm.read(8'h14, rd);
    check(rd == 0, $sformatf("unexpected errors %0d", rd));
    // 01 -> 10 double transition: 00 first
    step(1, 12); // st 3, 0  (00)
    step(1, 12);
    enc.jump(2'b11, 10);
    bfm.read(8'h14, rd);
    check(rd == 1, $sformatf("error count %0d exp 1", rd));
    bfm.read(8'h10, rd);
    check(rd[1] == 1, "error flag");
    bfm.write(8'h10, 32'h2);
    bfm.read(8'h10, rd);
    check(rd[1] == 0, "error W1C");
    // ---- Test 5: index latch and clear ----
    bfm.read(8'h04, rd);
    begin
      logic [31:0] p0;
      p0 = rd;
      enc.index(10);
      bfm.read(8'h18, rd);
      check(rd == p0, $sformatf("index pos %0d vs %0d", $signed(rd), $signed(p0)));
    end
    bfm.read(8'h10, rd);
    check(rd[2] == 1, "index flag");
    bfm.write(8'h00, 32'h0305);                        // index clears position
    enc.index(10);
    repeat (5) @(posedge aclk);
    bfm.read(8'h04, rd);
    check(rd == 0, "position not cleared by index");
    // ---- Test 6: position load ----
    bfm.write(8'h04, 32'd1000);
    repeat (2) @(posedge aclk);
    bfm.read(8'h04, rd);
    check(rd == 1000, "position load");
    // ---- Test 7: velocity samples: 1 count per 20 clocks -> ~20 counts / 400 ----
    vel_samples.delete();
    repeat (100) step(1, 20);
    check(vel_samples.size() >= 4, "no velocity samples");
    begin
      int mx;
      mx = 0;
      foreach (vel_samples[i]) if (vel_samples[i] > mx) mx = vel_samples[i];
      check(mx >= 19 && mx <= 21, $sformatf("velocity max %0d exp ~20", mx));
    end
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
