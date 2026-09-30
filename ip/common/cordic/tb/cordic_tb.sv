// ***************
// Filename: cordic_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for cordic. Rotation mode - random
//   vectors and angles over the full circle (all four quadrants and the
//   quadrant boundaries) are compared with double precision sin/cos; the
//   output pipeline delay must be ITER+2 clocks and back-to-back inputs
//   every clock must all come out in order. Vectoring mode - random points
//   in all quadrants are compared with sqrt and atan2. Prints TEST PASSED
//   on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module cordic_tb;
  localparam int W = 16, ZW = 16, IT = 16;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic v_i = 0; logic signed [W-1:0] xi = 0, yi = 0; logic [ZW-1:0] zi = 0;
  logic v_o; logic signed [W-1:0] xo, yo; logic [W:0] mo; logic [ZW-1:0] zo;
  logic v_v; logic signed [W-1:0] xv, yv; logic [W:0] mv; logic [ZW-1:0] zv;
  cordic #(.WIDTH(W), .ZW(ZW), .ITER(IT), .MODE(0)) rot (.clk, .rst_n, .valid_i(v_i), .x_i(xi), .y_i(yi), .z_i(zi), .valid_o(v_o), .x_o(xo), .y_o(yo), .mag_o(mo), .z_o(zo));
  cordic #(.WIDTH(W), .ZW(ZW), .ITER(IT), .MODE(1)) vec (.clk, .rst_n, .valid_i(v_i), .x_i(xi), .y_i(yi), .z_i(zi), .valid_o(v_v), .x_o(xv), .y_o(yv), .mag_o(mv), .z_o(zv));
  int errors = 0, nchk = 0; real maxerr_r = 0, maxerr_m = 0, maxerr_a = 0;
  // reference queues
  real ex_q[$], ey_q[$], em_q[$], ea_q[$]; real ax_q[$];
  localparam real PI = 3.14159265358979;
  always @(posedge clk) if (rst_n) begin
    if (v_i) begin
      real th, xr, yr;
      th = 2.0 * PI * zi / 65536.0;
      ex_q.push_back(xi * $cos(th) - yi * $sin(th)); ey_q.push_back(xi * $sin(th) + yi * $cos(th));
      em_q.push_back($sqrt(1.0 * xi * xi + 1.0 * yi * yi)); ea_q.push_back($atan2(1.0 * yi, 1.0 * xi));
    end
  end
  int lat_cnt = 0; int first_in = -1, first_out = -1, cyc = 0;
  always @(posedge clk) begin cyc++; if (v_i && first_in < 0) first_in = cyc; if (v_o && first_out < 0) first_out = cyc; end
  // Check outputs in order
  real rx, ry, rm, ra, d; int qi = 0;
  always @(posedge clk) if (rst_n && v_o) begin
    rx = ex_q[qi]; ry = ey_q[qi];
    d = (xo > rx) ? xo - rx : rx - xo; if (d > maxerr_r) maxerr_r = d;
    if (d > 4.0) begin errors++; $display("ERROR rot x: %0d exp %f (z=%0d)", xo, rx, qi); end
    d = (yo > ry) ? yo - ry : ry - yo; if (d > maxerr_r) maxerr_r = d;
    if (d > 4.0) begin errors++; $display("ERROR rot y: %0d exp %f", yo, ry); end
    rm = em_q[qi]; d = (mv > rm) ? mv - rm : rm - mv;
    qi++;
  end
  int qv = 0;
  always @(posedge clk) if (rst_n && v_v) begin
    real am, aa, ang, dm, da;
    am = em_q[qv]; aa = ea_q[qv]; ang = 65536.0 * aa / (2.0 * PI); if (ang < 0) ang += 65536.0;
    dm = (mv > am) ? mv - am : am - mv; if (dm > maxerr_m) maxerr_m = dm;
    if (dm > 4.0) begin errors++; $display("ERROR mag %0d exp %f", mv, am); end
    da = zv - ang; if (da > 32768) da -= 65536; if (da < -32768) da += 65536; if (da < 0) da = -da;
    if (da > maxerr_a) maxerr_a = da;
    if (am > 500.0 && da > 6.0 + 65536.0 * 4.0 / (2.0 * PI * am)) begin errors++; $display("ERROR angle %0d exp %f (|v|=%f)", zv, ang, am); end
    qv++;
  end
  task automatic drive(input int x, input int y, input int z);
    @(posedge clk); #1 v_i = 1; xi = x; yi = y; zi = z;
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("cordic_tb.vcd"); $dumpvars(0, cordic_tb); end
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    // angle sweep at fixed amplitude, back-to-back
    for (int a = 0; a < 512; a++) drive(30000, 0, a * 128);
    // quadrant boundaries
    for (int q = 0; q < 4; q++) begin drive(20000, 5000, q * 16384); drive(-12000, 9000, q * 16384 + 1); drive(1000, -1000, q * 16384 - 1); end
    for (int n = 0; n < 3000; n++) begin
      int x, y; x = $urandom_range(0, 40000) - 20000; y = $urandom_range(0, 40000) - 20000;
      if (x * x + 1.0 * y * y > 30000.0 * 30000.0) begin x = x / 2; y = y / 2; end
      drive(x, y, $urandom);
    end
    // vectoring-only: small and axis points
    drive(1, 0, 0); drive(0, 1, 0); drive(-1, 0, 0); drive(0, -1, 0); drive(-30000, 0, 0); drive(0, -30000, 0); drive(0, 30000, 0); drive(30000, 0, 0);
    @(posedge clk); #1 v_i = 0;
    repeat (IT + 10) @(posedge clk);
    if (qi != qv || qi != ex_q.size()) begin errors++; $display("ERROR output count rot %0d vec %0d in %0d", qi, qv, ex_q.size()); end
    if (first_out - first_in != IT + 2) begin errors++; $display("ERROR latency %0d expected %0d", first_out - first_in, IT + 2); end
    $display("max err: rot %f LSB, mag %f LSB, angle %f units", maxerr_r, maxerr_m, maxerr_a);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
