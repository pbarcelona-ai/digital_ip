// ***************
// Filename: pwm_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the PWM IP. Measures duty cycle
//   and period in edge aligned and center aligned modes, double-buffered
//   duty update at the period boundary, prescaler, output inversion and
//   complementary outputs with dead time (never both high, gap equals
//   DEADTIME). Prints TEST PASSED on success.
//   The test tasks are in tests/pwm_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module pwm_tb;
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
  logic [3:0] pwm, pwm_n;
  logic pp;
  pwm_top #(.CHANNELS(4)) dut (
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
    .pwm_o(pwm),
    .pwm_n_o(pwm_n),
    .period_pulse_o(pp)
  );
  int errors = 0;
  logic [31:0] rd;
  // used by task measure (tests/pwm_tests.sv)
  int hi_cnt, per_cnt;
  int both_high = 0, gap_min = 1000, gap = 0, prev_any = 0;
  always @(posedge aclk) begin
    if (pwm[3] && pwm_n[3]) both_high++;
  end
  // test tasks: tests/pwm_tests.sv
  `include "pwm_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("pwm_tb.vcd");
      $dumpvars(0, pwm_tb);
    end
    repeat (4) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);
    bfm.base = 'h10;                                 // the map after the ID block
    test_id_block();
    test_setup();
    test_edge_aligned();
    test_duty_update();
    test_invert();
    test_prescale();
    test_center();
    test_complementary();

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
