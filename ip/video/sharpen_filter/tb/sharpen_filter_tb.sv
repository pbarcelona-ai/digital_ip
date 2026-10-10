// ***************
// Filename: sharpen_filter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sharpen_filter, N = 5, AMOUNT = 2 (unsharp mask), RGB
//   8-bit. Checks the ID, the reset kernel and SHIFT read back as the
//   conv2d_pkg definition, filters frames with the reset kernel (random gaps
//   and back-pressure) and after reprogramming it to the identity kernel
//   (pass-through). Compared with conv2d_ref. Prints TEST PASSED.
//   The test tasks are in tests/sharpen_filter_tests.sv (`included).
// Date: 2026-10-08
`timescale 1ns/1ps
module sharpen_filter_tb;
  localparam int N = 5, C = 3, CW = 8, AMT = 2, MAXW = 32, MAXH = 16, NN = N * N;
  localparam logic [25*32-1:0] KERNEL = conv2d_pkg::sharpen_kernel(N, AMT);
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  initial begin
    #50ms;
    $display("ERROR: timeout");
    $display("TEST FAILED");
    $finish;
  end

  logic [7:0] s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  logic [C*CW-1:0] sd, md;
  logic sl, su, sv, sr, ml, mu, mv, mr;

  sharpen_filter #(
    .N(N),
    .C(C),
    .CW(CW),
    .MAX_W(64),
    .AMOUNT(AMT),
    .RESET_W(16'd12),
    .RESET_H(16'd8)
  ) dut (
    .clk,
    .rst_n,
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
    .s_axis_tdata(sd),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .m_axis_tdata(md),
    .m_axis_tlast(ml),
    .m_axis_tuser(mu),
    .m_axis_tvalid(mv),
    .m_axis_tready(mr)
  );
  axil_bfm #(.ADDR_W(8)) bfm (
    .aclk(clk),
    .*
  );
  axis_frame_bfm #(
    .DW(C*CW),
    .MAXW(MAXW),
    .MAXH(MAXH)
  ) vid (
    .clk,
    .s_tdata(sd),
    .s_tlast(sl),
    .s_tuser(su),
    .s_tvalid(sv),
    .s_tready(sr),
    .m_tdata(md),
    .m_tlast(ml),
    .m_tuser(mu),
    .m_tvalid(mv),
    .m_tready(mr)
  );
  conv2d_ref #(
    .N(N),
    .C(C),
    .CW(CW),
    .MAXW(MAXW),
    .MAXH(MAXH)
  ) mdl ();

  int W = 12, H = 8;
  // test tasks: tests/sharpen_filter_tests.sv
  `include "sharpen_filter_tests.sv"

  initial begin
    logic [31:0] v;
    int kbad;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    rd(16'h00, v);
    check(v == 32'h5348_5250, $sformatf("ID %h", v));
    rd(16'h08, v);
    check(v == conv2d_pkg::blur_shift(N), $sformatf("SHIFT %0d", v));
    rd(16'h04, v);
    check(v == {16'd8, 16'd12}, $sformatf("FRAME_SIZE %h", v));
    kbad = 0;
    for (int i = 0; i < NN; i++) begin
      rd(16'h40 + 4 * i, v);
      if (v != KERNEL[i*32 +: 32]) kbad++;
    end
    check(kbad == 0, $sformatf("%0d reset coefficients differ from conv2d_pkg", kbad));

    vid.gap_pct = 20;
    vid.bp_pct = 30;
    mdl.set_kernel(KERNEL, conv2d_pkg::blur_shift(N));
    run_frame("reset kernel");
    run_frame("reset kernel, second frame");
    $display("reset kernel: frames match the model");

    for (int i = 0; i < NN; i++) wr(16'h40 + 4 * i, (i == NN / 2) ? 1 : 0);
    wr(16'h08, 0);
    mdl.set_identity();
    run_frame("identity (pass-through)");
    $display("reprogrammed to identity: output = input");

    check(vid.errors == 0, $sformatf("%0d stream protocol errors", vid.errors));
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  // Waveform dump: +vcd writes sharpen_filter_tb.vcd (scripts/run_sim.sh --vcd / --wave, make wave)
  initial if ($test$plusargs("vcd")) begin
    $dumpfile("sharpen_filter_tb.vcd");
    $dumpvars(0, sharpen_filter_tb);
  end
endmodule
