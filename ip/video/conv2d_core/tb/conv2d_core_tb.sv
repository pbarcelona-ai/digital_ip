// ***************
// Filename: conv2d_core_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for conv2d_core with N = 3, one
//   10-bit component and BORDER = 1 (mirror): identity, blur, sharpen and
//   random kernels driven directly on coef_i / shift_i, random gaps and
//   back-pressure; the kernel inputs are changed mid-frame (must only apply
//   at the next frame) and the latency must not depend on the kernel.
//   Compared with conv2d_ref. Prints TEST PASSED on success.
//   The test tasks are in tests/conv2d_core_tests.sv (`included).
// Date: 2026-10-08
`timescale 1ns/1ps
module conv2d_core_tb;
  localparam int N = 3, C = 1, CW = 10, COEF_W = 12, MAXW = 32, MAXH = 16, NN = N * N;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  initial begin #50ms; $display("ERROR: timeout"); $display("TEST FAILED"); $finish; end

  logic [NN*COEF_W-1:0] coef; logic [4:0] shift; logic [15:0] w, h;
  logic [C*CW-1:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr, fr;
  conv2d_core #(.N(N), .C(C), .CW(CW), .COEF_W(COEF_W), .MAX_W(64), .BORDER(1)) dut (.clk, .rst_n,
    .width_i(w), .height_i(h), .coef_i(coef), .shift_i(shift),
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr), .frame_o(fr), .sof_wait_o());
  axis_frame_bfm #(.DW(C*CW), .MAXW(MAXW), .MAXH(MAXH)) vid (.clk,
    .s_tdata(sd), .s_tlast(sl), .s_tuser(su), .s_tvalid(sv), .s_tready(sr),
    .m_tdata(md), .m_tlast(ml), .m_tuser(mu), .m_tvalid(mv), .m_tready(mr));
  conv2d_ref #(.N(N), .C(C), .CW(CW), .MAXW(MAXW), .MAXH(MAXH), .BORDER(1)) mdl ();

  function automatic logic [25*32-1:0] random_kernel();
    logic [25*32-1:0] kp; kp = '0;
    for (int i = 0; i < NN; i++) kp[i*32 +: 32] = 32'($urandom_range(1000) - 500);
    return kp;
  endfunction
  int W = 11, H = 7;
  // test tasks: tests/conv2d_core_tests.sv
  `include "conv2d_core_tests.sv"

  initial begin
    realtime lat [4];
    logic [25*32-1:0] ka, kb;
    w = 16'(W); h = 16'(H);
    use_kernel(conv2d_pkg::identity_kernel(N), 0);
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);

    // 1. kernels, no gaps: the latency must be the same for each
    new_image(); run_frame("identity");                                               lat[0] = vid.out_sof_t - vid.in_sof_t;
    use_kernel(conv2d_pkg::blur_kernel(N), conv2d_pkg::blur_shift(N));
    new_image(); run_frame("blur");                                                   lat[1] = vid.out_sof_t - vid.in_sof_t;
    use_kernel(conv2d_pkg::sharpen_kernel(N, 3), conv2d_pkg::blur_shift(N));
    new_image(); run_frame("sharpen x3");                                             lat[2] = vid.out_sof_t - vid.in_sof_t;
    use_kernel(random_kernel(), 7);
    new_image(); run_frame("random");                                                 lat[3] = vid.out_sof_t - vid.in_sof_t;
    check(lat[0] == lat[1] && lat[1] == lat[2] && lat[2] == lat[3],
          $sformatf("latency depends on the kernel: %0t %0t %0t %0t", lat[0], lat[1], lat[2], lat[3]));
    $display("identity, blur, sharpen, random (N = 3, mirror border): match, latency %0t for all", lat[0]);

    // 2. gaps, back-pressure, random kernels and shifts
    vid.gap_pct = 25; vid.bp_pct = 35;
    for (int t = 0; t < 5; t++) begin
      use_kernel(random_kernel(), $urandom_range(12));
      new_image(); run_frame($sformatf("random kernel %0d with gaps / back-pressure", t));
    end
    $display("random kernels with gaps and back-pressure: match");

    // 3. kernel inputs changed during a frame (after its first window)
    ka = conv2d_pkg::blur_kernel(N); kb = random_kernel();
    use_kernel(ka, conv2d_pkg::blur_shift(N));
    new_image();
    begin
      int f0; f0 = vid.frames; vid.ow = W; vid.oh = H;
      fork
        vid.send(W, H);
        begin
          while (!(mv && mr && mu)) @(posedge clk);
          for (int i = 0; i < NN; i++) coef[i*COEF_W +: COEF_W] = kb[i*32 +: COEF_W];
          shift = 5'd4;
        end
      join
      while (vid.frames < f0 + 1) @(posedge clk);
      mdl.run(W, H); compare("kernel changed mid-frame (old kernel)");
    end
    mdl.set_kernel(kb, 4); new_image(); run_frame("next frame (new kernel)");
    $display("kernel change mid-frame: applied from the next frame");

    check(vid.errors == 0, $sformatf("%0d stream protocol errors", vid.errors));
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
