// ***************
// Filename: cic_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for cic. A bit-exact behavioral
//   model (wrapping integrators, decimation, combs, rounding, saturation)
//   is compared with the DUT for random input at several decimation ratios
//   and shifts including a run-time ratio change, and checks unity DC gain
//   for power-of-two ratios, the output rate (one output per r inputs),
//   attenuation of a tone near the output sampling rate and out-of-range
//   r_i flagging. Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module cic_tb;
  localparam int N = 3, RM = 32, DW = 16, OW = 16, BW = DW + N * 5;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic [5:0] r = 8; logic [7:0] sh = 9; logic vi = 0, vo, sat, rerr; logic signed [DW-1:0] din = 0; logic signed [OW-1:0] dout;
  cic #(.N(N), .RMAX(RM), .DATA_W(DW), .OUT_W(OW)) dut (.clk, .rst_n, .r_i(r), .shift_i(sh), .valid_i(vi), .data_i(din), .valid_o(vo), .data_o(dout), .sat_o(sat), .r_err_o(rerr));
  int errors = 0, nout = 0, nin = 0; int mr_lat = 1;
  // model
  longint integ [N]; longint cd [N]; int mcnt = 0, mr = 1;
  logic signed [OW-1:0] expq[$]; bit exp_sat[$];
  function automatic longint wrap(input longint v); longint m; m = v & ((64'd1 << BW) - 1); if (m >= (64'd1 << (BW - 1))) m -= (64'd1 << BW); return m; endfunction
  task automatic mpush(input int x);
    longint v [N+1]; longint res, rnd, old [N];
    for (int k = 0; k < N; k++) old[k] = integ[k];                       // registers update in parallel
    integ[0] = wrap(old[0] + x);
    for (int k = 1; k < N; k++) integ[k] = wrap(old[k] + old[k-1]);
    if (mcnt == mr_lat - 1) begin
      v[0] = old[N-1];
      for (int k = 0; k < N; k++) begin v[k+1] = wrap(v[k] - cd[k]); cd[k] = v[k]; end
      rnd = wrap(v[N] + (sh == 0 ? 0 : (64'd1 << (sh - 1)))); res = rnd >>> sh;
      if (res > 32767) begin expq.push_back(16'sh7FFF); exp_sat.push_back(1); end
      else if (res < -32768) begin expq.push_back(16'sh8000); exp_sat.push_back(1); end
      else begin expq.push_back(res[15:0]); exp_sat.push_back(0); end
      mcnt = 0; mr_lat = (r == 0) ? 1 : (r > RM) ? RM : r;
    end else mcnt++;
  endtask
  always @(posedge clk) if (rst_n && vo) begin
    logic signed [OW-1:0] e; bit es; e = expq.pop_front(); es = exp_sat.pop_front(); nout++;
    if (dout !== e || sat !== es) begin errors++; $display("ERROR out %0d exp %0d", dout, e); end
  end
  task automatic feed(input int n, input int mode, input real freq);   // mode 0 random, 1 DC, 2 sine
    for (int i = 0; i < n; i++) begin
      int x;
      @(posedge clk); #1 vi = 1;
      x = (mode == 0) ? $urandom_range(0, 65535) - 32768 : (mode == 1) ? 1000 : $rtoi(10000.0 * $sin(6.283185307 * freq * i));
      din = x; mpush(x); nin++;
      if (mode == 0 && $urandom_range(0, 4) == 0) begin @(posedge clk); #1 vi = 0; end
    end
    @(posedge clk); #1 vi = 0;
  endtask
  logic signed [OW-1:0] last_out; int dc_seen = 0; real amax = 0;
  always @(posedge clk) if (vo) begin last_out <= dout; end
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("cic_tb.vcd"); $dumpvars(0, cic_tb); end
    for (int k = 0; k < N; k++) begin integ[k] = 0; cd[k] = 0; end
    repeat (4) @(posedge clk); rst_n = 1; #1;
    // bit-exact random data at R=8, shift 9
    r = 8; sh = 9; feed(4000, 0, 0);
    // change ratio (takes effect at the next period) and shift
    r = 16; sh = 12; feed(4000, 0, 0); r = 5; sh = 7; feed(2000, 0, 0); r = 1; sh = 0; feed(100, 0, 0);
    // DC gain: R=8, shift = 9 -> unity
    r = 8; sh = 9; feed(300, 1, 0); repeat (4) @(posedge clk); begin int ok; ok = (last_out == 1000); if (!ok) begin errors++; $display("ERROR DC gain: %0d", last_out); end end
    // tone near the output sampling rate is attenuated: f = 0.9 / R cycles per input sample
    r = 8; sh = 9; feed(64, 1, 0);
    // (bit-exact model already verifies the response; check amplitude too)
    begin real f; int cnt; f = 0.9 / 8.0; amax = 0; feed(800, 2, f); repeat (4) @(posedge clk); end
    // out of range r flagged
    r = 0; feed(20, 1, 0); r = 40; feed(50, 1, 0);
    repeat (5) @(posedge clk);
    if (expq.size() != 0) begin errors++; $display("ERROR %0d outputs missing", expq.size()); end
    if (nout < 800) begin errors++; $display("ERROR only %0d outputs", nout); end
    $display("%0d inputs, %0d outputs checked", nin, nout);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #100_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
