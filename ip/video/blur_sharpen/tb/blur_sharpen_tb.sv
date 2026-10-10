// ***************
// Filename: blur_sharpen_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for blur_sharpen (N = 5, RGB 8-bit).
//   Register readback (ID, INFO, reset MODE and kernels); every MODE
//   (blur, sharpen, sharpen->blur, blur->sharpen, pass-through) against a
//   two-stage conv2d_ref chain, with the same latency in every mode;
//   random gaps and back-pressure; reprogrammed blur / sharpen kernels and
//   shifts (and a check that the two orders really differ); MODE written in
//   the middle of a frame (that frame keeps the old mode); the smallest
//   frame height (3). Prints TEST PASSED on success.
//   The test tasks are in tests/blur_sharpen_tests.sv (`included).
// Date: 2026-10-08
`timescale 1ns/1ps
module blur_sharpen_tb;
  localparam int N = 5, C = 3, CW = 8, MAXW = 32, MAXH = 16, NN = N * N;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  initial begin
    #100ms;
    $display("ERROR: timeout");
    $display("TEST FAILED");
    $finish;
  end

  logic [8:0] s_axil_awaddr, s_axil_araddr;
  logic s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
  logic [31:0] s_axil_wdata, s_axil_rdata;
  logic [3:0] s_axil_wstrb;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  logic [C*CW-1:0] sd, md;
  logic sl, su, sv, sr, ml, mu, mv, mr;

  blur_sharpen #(
    .N(N),
    .C(C),
    .CW(CW),
    .MAX_W(64)
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
  axil_bfm #(.ADDR_W(9)) bfm (
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

  // used by task program_banks (tests/blur_sharpen_tests.sv)
  logic [25*32-1:0] kb, ks;
  int sb, ss;

  int W = 12, H = 8;
  logic [23:0] src [MAXH][MAXW];
  logic [23:0] res [MAXH][MAXW];
  // test tasks: tests/blur_sharpen_tests.sv
  `include "blur_sharpen_tests.sv"

  string mname [5] = '{"blur", "sharpen", "sharpen->blur", "blur->sharpen", "pass-through"};

  initial begin
    logic [31:0] v;
    int kbad;
    realtime lat [5];
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);

    // 1. registers
    rd(16'h000, v);
    check(v == 32'h424C_5348, $sformatf("ID %h", v));
    rd(16'h018, v);
    check(v == {8'd8, 8'd3, 4'd0, 4'd12, 4'd0, 4'd5}, $sformatf("INFO %h", v));
    rd(16'h004, v);
    check(v == 0, $sformatf("reset MODE %0d", v));
    kb = conv2d_pkg::blur_kernel(N);
    ks = conv2d_pkg::sharpen_kernel(N, 1);
    sb = conv2d_pkg::blur_shift(N);
    ss = sb;
    kbad = 0;
    for (int i = 0; i < NN; i++) begin
      rd(16'h40 + 4 * i, v);
      if (v != kb[i*32 +: 32]) kbad++;
      rd(16'hC0 + 4 * i, v);
      if (v != ks[i*32 +: 32]) kbad++;
    end
    check(kbad == 0, $sformatf("%0d reset coefficients differ from conv2d_pkg", kbad));
    wr(16'h008, (H << 16) | W);

    // 2. every mode, reset kernels, no gaps: same latency
    for (int m = 0; m < 5; m++) begin
      wr(16'h004, m);
      new_image();
      run_frame(m, $sformatf("mode %0d (%s)", m, mname[m]));
      lat[m] = vid.out_sof_t - vid.in_sof_t;
      rd(16'h014, v);
      check(v[2:0] == m, $sformatf("STATUS mode %0d, expected %0d", v[2:0], m));
    end
    check(lat[0] == lat[1] && lat[1] == lat[2] && lat[2] == lat[3] && lat[3] == lat[4],
          $sformatf("latency differs between modes: %0t %0t %0t %0t %0t", lat[0], lat[1], lat[2], lat[3], lat[4]));
    $display("modes 0-4 (blur, sharpen, sharpen->blur, blur->sharpen, pass-through): match, latency %0t in every mode", lat[0]);

    // 3. gaps and back-pressure, modes in another order
    vid.gap_pct = 25;
    vid.bp_pct = 30;
    for (int t = 0; t < 6; t++) begin
      int m;
      m = (t * 3 + 2) % 5;
      wr(16'h004, m);
      new_image();
      run_frame(m, $sformatf("mode %0d with gaps / back-pressure", m));
    end
    $display("all modes with gaps and back-pressure: match");

    // 4. reprogrammed kernels: 3 x 3 blur inside the 5 x 5, stronger sharpen
    begin
      logic [25*32-1:0] b3;
      b3 = '0;
      for (int r = 0; r < 3; r++) for (int c = 0; c < 3; c++)
        b3[((r + 1) * N + c + 1) * 32 +: 32] = 32'(conv2d_pkg::binom(3, r) * conv2d_pkg::binom(3, c));
      program_banks(b3, 4, conv2d_pkg::sharpen_kernel(N, 3), 8);
    end
    new_image();
    wr(16'h004, 2);
    run_frame(2, "custom kernels, sharpen->blur");
    begin
      logic [23:0] r2 [MAXH][MAXW];
      int diff;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) r2[y][x] = vid.out[y][x];
      wr(16'h004, 3);
      run_frame(3, "custom kernels, blur->sharpen");
      diff = 0;
      for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (vid.out[y][x] != r2[y][x]) diff++;
      check(diff > 0, "sharpen->blur and blur->sharpen gave the same image");
      $display("custom kernels: both orders match the model (%0d of %0d pixels differ between the orders)", diff, W * H);
    end

    // 5. MODE written during a frame: that frame keeps the old mode
    wr(16'h004, 0);
    new_image();
    run_frame(0, "blur before the change");
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
          wr(16'h004, 3);
        end
      join
      while (vid.frames < f0 + 1) @(posedge clk);
      model(0);
      compare("frame during the MODE write (old mode)");
    end
    new_image();
    run_frame(3, "next frame (new mode)");
    $display("MODE change mid-frame: applied from the next frame");

    // 6. smallest frame height for N = 5, back-to-back frames
    W = 6;
    H = 3;
    wr(16'h008, (H << 16) | W);
    for (int m = 0; m < 5; m++) begin
      wr(16'h004, m);
      new_image();
      run_frame(m, $sformatf("6x3 frame, mode %0d", m));
    end
    $display("6x3 frames: match in every mode");

    rd(16'h014, v);
    check(v[31:16] == vid.frames, $sformatf("STATUS frames %0d, %0d received", v[31:16], vid.frames));
    check(vid.errors == 0, $sformatf("%0d stream protocol errors", vid.errors));
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  // Waveform dump: +vcd writes blur_sharpen_tb.vcd (scripts/run_sim.sh --vcd / --wave, make wave)
  initial if ($test$plusargs("vcd")) begin
    $dumpfile("blur_sharpen_tb.vcd");
    $dumpvars(0, blur_sharpen_tb);
  end
endmodule
