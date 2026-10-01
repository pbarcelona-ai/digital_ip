// ***************
// Filename: dds_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for dds. Generates 1 MHz, 7.3 MHz
//   and 24.9 MHz tones at 100 MHz and compares every sin/cos sample with
//   double precision references computed from an independent model of the
//   phase accumulator, checks the pipeline latency, the amplitude range,
//   phase offset, sync load, enable gating and the Nyquist flag. Prints
//   TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module dds_tb;
  localparam int PW = 32, OW = 16, IT = 16;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  logic en = 0, ld = 0, vo, ny; logic [PW-1:0] tw = 0, off = 0, pl = 0; logic signed [OW-1:0] s, c;
  dds #(.PHASE_W(PW), .OUT_W(OW), .ZW(16), .ITER(IT)) dut (.clk, .rst_n, .en_i(en), .tuning_i(tw), .phase_off_i(off), .sync_load_i(ld), .phase_load_i(pl), .valid_o(vo), .sin_o(s), .cos_o(c), .nyquist_o(ny));
  localparam real TWO_PI = 6.283185307179586;
  int errors = 0, nchk = 0; real maxe = 0;
  // Independent model of the phase (nco: phase_o <= acc + tuning + offset each enabled clock)
  logic [PW-1:0] macc = 0; logic [PW-1:0] mq[$]; int cyc = 0, first_in = -1, first_out = -1;
  always @(posedge clk) begin
    cyc++;
    if (!rst_n) macc <= 0;
    else if (ld) begin macc <= pl; mq.push_back(pl + off); end
    else if (en) begin macc <= macc + tw; mq.push_back(macc + tw + off); if (first_in < 0) first_in = cyc; end
    if (vo && first_out < 0) first_out = cyc;
  end
  always @(posedge clk) if (rst_n && vo) begin
    real th, es, ec, d; logic [PW-1:0] p; p = mq.pop_front();
    th = TWO_PI * p[PW-1 -: 16] / 65536.0;
    es = 32767.0 * $sin(th); ec = 32767.0 * $cos(th);
    d = (s > es) ? s - es : es - s; if (d > maxe) maxe = d; if (d > 8.0) begin errors++; $display("ERROR sin %0d exp %f", s, es); end
    d = (c > ec) ? c - ec : ec - c; if (d > maxe) maxe = d; if (d > 8.0) begin errors++; $display("ERROR cos %0d exp %f", c, ec); end
    if (s > 32767 || s < -32768) errors++;
    nchk++;
  end
  task automatic tone(input real f_mhz, input int n);
    tw = $rtoi(f_mhz / 100.0 * 4294967296.0); @(posedge clk); #1 en = 1; repeat (n) @(posedge clk); #1 en = 0; repeat (IT + 10) @(posedge clk);
  endtask
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("dds_tb.vcd"); $dumpvars(0, dds_tb); end
    repeat (4) @(posedge clk); rst_n = 1; repeat (2) @(posedge clk);
    tone(1.0, 400); tone(7.3, 400); tone(24.9, 400);
    off = 32'h4000_0000; tone(3.0, 200); off = 0;                                   // quarter-turn phase offset
    @(posedge clk); #1 ld = 1; pl = 32'hC000_0000; @(posedge clk); #1 ld = 0; tone(2.0, 100);
    // enable gating: nothing valid while disabled
    begin int n0; n0 = nchk; repeat (50) @(posedge clk); if (nchk != n0) begin errors++; $display("ERROR samples while disabled"); end end
    tw = 32'h8000_0000; #1 if (!ny) begin errors++; $display("ERROR nyquist flag"); end
    if (first_out - first_in != IT + 3) begin errors++; $display("ERROR latency %0d expected %0d", first_out - first_in, IT + 3); end
    if (nchk < 1000 || mq.size() != 0) begin errors++; $display("ERROR checked %0d left %0d", nchk, mq.size()); end
    $display("checked %0d samples, max error %f LSB", nchk, maxe);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #20_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
