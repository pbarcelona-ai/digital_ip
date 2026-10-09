// ***************
// Filename: conv2d_filter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for conv2d_filter (N = 5, RGB 8-bit).
//   Register readback (ID, INFO, sign-extended coefficients), the identity
//   reset kernel (output = input), the conv2d_pkg blur and sharpen kernels,
//   random kernels with negative and large coefficients and random shifts
//   (clamping at 0 and full scale), random input gaps and output
//   back-pressure, two frame sizes, and a kernel written in the middle of a
//   frame (that frame keeps the old kernel, the next one uses the new one).
//   Every output pixel is compared with conv2d_ref. Prints TEST PASSED.
//   The test tasks are in tests/conv2d_filter_tests.sv (`included).
// Date: 2026-10-08
`timescale 1ns/1ps
module conv2d_filter_tb;
  localparam int N = 5, C = 3, CW = 8, MAXW = 32, MAXH = 16, NN = N * N;
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

  conv2d_filter #(.N(N), .C(C), .CW(CW), .MAX_W(64)) dut (
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
  axis_frame_bfm #(.DW(C*CW), .MAXW(MAXW), .MAXH(MAXH)) vid (
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
  conv2d_ref #(.N(N), .C(C), .CW(CW), .MAXW(MAXW), .MAXH(MAXH)) mdl ();

  function automatic logic [25*32-1:0] random_kernel();
    logic [25*32-1:0] kp;
    kp = '0;
    for (int i = 0; i < NN; i++) kp[i*32 +: 32] = 32'($urandom_range(600) - 300);
    return kp;
  endfunction

  int W = 13, H = 9;
  // test tasks: tests/conv2d_filter_tests.sv
  `include "conv2d_filter_tests.sv"

  initial begin
    logic [31:0] v;
    logic [25*32-1:0] ka, kb;
    int sa, sb;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    rd(16'h00, v);
    check(v == 32'h4332_4446, $sformatf("ID %h", v));
    rd(16'h10, v);
    check(v == {8'd8, 8'd3, 4'd0, 4'd12, 4'd0, 4'd5}, $sformatf("INFO %h", v));
    wr(16'h40, -5);
    rd(16'h40, v);
    check(v == 32'hFFFF_FFFB, $sformatf("K[0] readback %h", v));
    wr(16'h40, 0);
    wr(16'h04, (H << 16) | W);

    // 1. reset kernel: identity
    new_image();
    mdl.set_identity();
    run_frame("identity (reset kernel)");
    // 2. blur, sharpen
    new_image();
    program_kernel(conv2d_pkg::blur_kernel(N), conv2d_pkg::blur_shift(N));
    mdl.set_kernel(conv2d_pkg::blur_kernel(N), conv2d_pkg::blur_shift(N));
    run_frame("blur");
    new_image();
    program_kernel(conv2d_pkg::sharpen_kernel(N, 1), conv2d_pkg::blur_shift(N));
    mdl.set_kernel(conv2d_pkg::sharpen_kernel(N, 1), conv2d_pkg::blur_shift(N));
    run_frame("sharpen");
    $display("identity, blur, sharpen: frames match the model");

    // 3. random kernels, gaps and back-pressure, another frame size
    vid.gap_pct = 30;
    vid.bp_pct = 30;
    for (int t = 0; t < 6; t++) begin
      if (t == 3) begin
        W = 8;
        H = 5;
        wr(16'h04, (H << 16) | W);
      end
      ka = random_kernel();
      sa = $urandom_range(10);
      program_kernel(ka, sa);
      mdl.set_kernel(ka, sa);
      new_image();
      run_frame($sformatf("random kernel %0d (%0dx%0d, shift %0d)", t, W, H, sa));
    end
    $display("random kernels with gaps and back-pressure: frames match the model");

    // 4. kernel written during a frame: that frame keeps the old kernel
    W = 13;
    H = 9;
    wr(16'h04, (H << 16) | W);
    ka = conv2d_pkg::blur_kernel(N);
    sa = conv2d_pkg::blur_shift(N);
    kb = random_kernel();
    sb = 6;
    program_kernel(ka, sa);
    mdl.set_kernel(ka, sa);
    new_image();
    run_frame("before the change");
    new_image();
    begin
      int f0;
      f0 = vid.frames;
      vid.ow = W;
      vid.oh = H;
      fork
        vid.send(W, H);
        begin
          while (vid.sent < W * H / 2 + 1) @(posedge clk);
          program_kernel(kb, sb);
        end
      join
      while (vid.frames < f0 + 1) @(posedge clk);
      mdl.run(W, H);
      compare("frame during the kernel write (old kernel)");
    end
    mdl.set_kernel(kb, sb);
    new_image();
    run_frame("next frame (new kernel)");
    $display("kernel change mid-frame: applied from the next frame");

    rd(16'h0C, v);
    check(v[15:0] == 12, $sformatf("STATUS frames %0d", v[15:0]));
    check(vid.errors == 0, $sformatf("%0d stream protocol errors", vid.errors));
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  // Waveform dump: +vcd writes conv2d_filter_tb.vcd (scripts/run_sim.sh --vcd / --wave, make wave)
  initial if ($test$plusargs("vcd")) begin
    $dumpfile("conv2d_filter_tb.vcd");
    $dumpvars(0, conv2d_filter_tb);
  end
endmodule
