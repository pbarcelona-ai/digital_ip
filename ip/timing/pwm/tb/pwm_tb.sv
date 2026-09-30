// ***************
// Filename: pwm_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the PWM IP. Measures duty cycle
//   and period in edge aligned and center aligned modes, double-buffered
//   duty update at the period boundary, prescaler, output inversion and
//   complementary outputs with dead time (never both high, gap equals
//   DEADTIME). Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module pwm_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  // AXI-Lite wires (names match DUT ports so .* connects the BFM)
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready;
  logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [3:0] pwm, pwm_n; logic pp;
  pwm_top #(.CHANNELS(4)) dut (.aclk, .aresetn,
.s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .pwm_o(pwm), .pwm_n_o(pwm_n), .period_pulse_o(pp));
  int errors = 0; logic [31:0] rd;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask
  // Measure high count of channel ch and period length over one full period
  int hi_cnt, per_cnt;
  task automatic measure(input int ch);
    @(posedge pp); #1; hi_cnt = 0; per_cnt = 0;
    do begin @(posedge aclk); #1; per_cnt++; hi_cnt += pwm[ch]; end while (!pp);
  endtask
  int both_high = 0, gap_min = 1000, gap = 0, prev_any = 0;
  always @(posedge aclk) begin
    if (pwm[3] && pwm_n[3]) both_high++;
  end
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("pwm_tb.vcd"); $dumpvars(0, pwm_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    bfm.write(8'h04, 99);                    // period 100 clocks
    bfm.write(8'h14, 25); bfm.write(8'h18, 50); bfm.write(8'h1C, 75); bfm.write(8'h20, 10);
    bfm.write(8'h00, 32'h1);
    // ---- Test 1: edge aligned duty ----
    measure(0); measure(0);
    check(per_cnt == 100 && hi_cnt == 25, $sformatf("ch0 period %0d duty %0d", per_cnt, hi_cnt));
    measure(1); check(hi_cnt == 50, $sformatf("ch1 duty %0d", hi_cnt));
    measure(2); check(hi_cnt == 75, $sformatf("ch2 duty %0d", hi_cnt));
    check(pwm_n == ~pwm, "non-complementary mode: pwm_n is inverse");
    // ---- Test 2: duty update takes effect at the period boundary ----
    @(posedge pp); repeat (10) @(posedge aclk);
    bfm.write(8'h14, 60);
    measure(0);                               // remainder of the current period
    measure(0); check(hi_cnt == 60, $sformatf("updated duty %0d", hi_cnt));
    // ---- Test 3: inversion ----
    bfm.write(8'h10, 32'h1); measure(0); measure(0);
    check(hi_cnt == 40, $sformatf("inverted duty %0d", hi_cnt));
    bfm.write(8'h10, 32'h0);
    // ---- Test 4: prescaler /4 -> period 400 ----
    bfm.write(8'h08, 3); measure(0); measure(0);
    check(per_cnt == 400 && hi_cnt == 240, $sformatf("presc period %0d duty %0d", per_cnt, hi_cnt));
    bfm.write(8'h08, 0);
    // ---- Test 5: center aligned: period 2*99, high = 2*duty ----
    bfm.write(8'h00, 32'h3); bfm.write(8'h14, 20); measure(0); measure(0);
    check(per_cnt >= 197 && per_cnt <= 200, $sformatf("center period %0d", per_cnt));
    check(hi_cnt >= 38 && hi_cnt <= 41, $sformatf("center duty %0d", hi_cnt));
    // ---- Test 6: complementary with dead time 5 on channel 3 ----
    bfm.write(8'h00, 32'h1 | 32'h4); bfm.write(8'h0C, 5);
    bfm.write(8'h04, 99); bfm.write(8'h20, 40);
    begin
      int idle_run, max_gap, saw_gap;
      idle_run = 0; max_gap = 0; saw_gap = 0;
      repeat (3) @(posedge pp);
      repeat (300) begin
        @(posedge aclk);
        if (!pwm[3] && !pwm_n[3]) begin idle_run++; end
        else begin if (idle_run > 0) begin saw_gap++; if (idle_run > max_gap) max_gap = idle_run; end idle_run = 0; end
      end
      check(both_high == 0, "complementary outputs overlapped");
      check(saw_gap >= 4 && max_gap >= 5 && max_gap <= 7, $sformatf("dead gap %0d (%0d gaps)", max_gap, saw_gap));
    end
    check(bfm.resp_errors == 0, "axi errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #5_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
