// ***************
// Filename: sharpen_filter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sharpen_filter, N = 5, AMOUNT = 2 (unsharp mask), RGB
//   8-bit. Checks the ID, the reset kernel and SHIFT read back as the
//   conv2d_pkg definition, filters frames with the reset kernel (random gaps
//   and back-pressure) and after reprogramming it to the identity kernel
//   (pass-through). Compared with conv2d_ref. Prints TEST PASSED.
// Date: 2026-10-08
`timescale 1ns/1ps
module sharpen_filter_tb;
  localparam int N = 5, C = 3, CW = 8, AMT = 2, MAXW = 32, MAXH = 16, NN = N * N;
  localparam logic [25*32-1:0] KERNEL = conv2d_pkg::sharpen_kernel(N, AMT);
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin #50ms; $display("ERROR: timeout"); $display("TEST FAILED"); $finish; end

  logic [7:0] s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb; logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  logic [C*CW-1:0] sd, md; logic sl, su, sv, sr, ml, mu, mv, mr;

  sharpen_filter #(.N(N), .C(C), .CW(CW), .MAX_W(64), .AMOUNT(AMT), .RESET_W(16'd12), .RESET_H(16'd8)) dut (.clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata(sd), .s_axis_tlast(sl), .s_axis_tuser(su), .s_axis_tvalid(sv), .s_axis_tready(sr),
    .m_axis_tdata(md), .m_axis_tlast(ml), .m_axis_tuser(mu), .m_axis_tvalid(mv), .m_axis_tready(mr));
  axil_bfm #(.ADDR_W(8)) bfm (.aclk(clk), .*);
  axis_frame_bfm #(.DW(C*CW), .MAXW(MAXW), .MAXH(MAXH)) vid (.clk,
    .s_tdata(sd), .s_tlast(sl), .s_tuser(su), .s_tvalid(sv), .s_tready(sr),
    .m_tdata(md), .m_tlast(ml), .m_tuser(mu), .m_tvalid(mv), .m_tready(mr));
  conv2d_ref #(.N(N), .C(C), .CW(CW), .MAXW(MAXW), .MAXH(MAXH)) mdl ();

  task automatic wr(input int a, input int d); bfm.write(8'(a), 32'(d)); endtask
  task automatic rd(input int a, output logic [31:0] d); bfm.read(8'(a), d); endtask
  int W = 12, H = 8;
  task automatic run_frame(input string what);
    int f0, bad; f0 = vid.frames; vid.ow = W; vid.oh = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [23:0] p; p = ((x / 3 + y / 2) % 2) ? 24'hF0E0D0 : 24'h102030;     // edges to blur / sharpen
      if ($urandom_range(4) == 0) p = $urandom;
      vid.img[y][x] = p; mdl.img[y][x] = p;
    end
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    mdl.run(W, H); bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask

  initial begin
    logic [31:0] v; int kbad;
    repeat (5) @(posedge clk); rst_n = 1; repeat (5) @(posedge clk);
    rd(16'h00, v); check(v == 32'h5348_5250, $sformatf("ID %h", v));
    rd(16'h08, v); check(v == conv2d_pkg::blur_shift(N), $sformatf("SHIFT %0d", v));
    rd(16'h04, v); check(v == {16'd8, 16'd12}, $sformatf("FRAME_SIZE %h", v));
    kbad = 0;
    for (int i = 0; i < NN; i++) begin rd(16'h40 + 4 * i, v); if (v != KERNEL[i*32 +: 32]) kbad++; end
    check(kbad == 0, $sformatf("%0d reset coefficients differ from conv2d_pkg", kbad));

    vid.gap_pct = 20; vid.bp_pct = 30;
    mdl.set_kernel(KERNEL, conv2d_pkg::blur_shift(N));
    run_frame("reset kernel");
    run_frame("reset kernel, second frame");
    $display("reset kernel: frames match the model");

    for (int i = 0; i < NN; i++) wr(16'h40 + 4 * i, (i == NN / 2) ? 1 : 0);
    wr(16'h08, 0);
    mdl.set_identity(); run_frame("identity (pass-through)");
    $display("reprogrammed to identity: output = input");

    check(vid.errors == 0, $sformatf("%0d stream protocol errors", vid.errors));
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
