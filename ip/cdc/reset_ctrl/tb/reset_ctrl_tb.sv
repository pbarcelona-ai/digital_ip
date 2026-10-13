// ***************
// Filename: reset_ctrl_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the reset synchronizer IP.
//   Checks asynchronous assertion, synchronous de-assertion, minimum pulse
//   stretch on a sub-clock glitch, software reset through AXI-Lite, event
//   counter, sticky flag write-1-to-clear and register readback. Prints
//   TEST PASSED on success. Use +vcd to dump sim/reset_ctrl_tb.vcd for
//   Surfer.
//   The test tasks are in tests/reset_ctrl_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module reset_ctrl_tb;
  localparam real CLK_PERIOD = 10.0;        // 100 MHz
  localparam int  NUM_OUT    = 4;
  localparam int  HOLD       = 16;

  logic aclk = 0, arst_i;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  // AXI-Lite signals
  logic [7:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [NUM_OUT-1:0] rst_o;
  logic bus_rst_n;

  ip_reset_sync_top #(
    .NUM_OUT(NUM_OUT),
    .HOLD_DEFAULT(HOLD)
  ) dut (
    .aclk,
    .arst_i,
    .s_axil_awaddr(awaddr),
    .s_axil_awvalid(awvalid),
    .s_axil_awready(awready),
    .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb),
    .s_axil_wvalid(wvalid),
    .s_axil_wready(wready),
    .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid),
    .s_axil_bready(bready),
    .s_axil_araddr(araddr),
    .s_axil_arvalid(arvalid),
    .s_axil_arready(arready),
    .s_axil_rdata(rdata),
    .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .rst_o,
    .bus_rst_n_o(bus_rst_n)
  );

  int errors = 0;

  // used by task measure_low (tests/reset_ctrl_tests.sv)
  int low_cycles;
  // test tasks: tests/reset_ctrl_tests.sv
  logic [7:0] reg_base = 8'h10;                   // the register map after the ID block
  logic [1:0] last_bresp;

  logic [31:0] rd;
  logic changed_off_edge = 0;
  // Output must only de-assert on a clock edge (synchronous release)
  always @(posedge rst_o[0]) if ($time % 10000 != 0 && $realtime > 200)
    if (arst_i == 1'b1 && aclk !== 1'b1) changed_off_edge = 1;

  `include "reset_ctrl_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("reset_ctrl_tb.vcd");
      $dumpvars(0, reset_ctrl_tb);
    end
    awvalid = 0;
    wvalid = 0;
    bready = 0;
    arvalid = 0;
    rready = 0;
    awaddr = 0;
    araddr = 0;
    wdata = 0;
    wstrb = 0;

    test_power_up();
    test_id_block();
    test_glitch();
    test_registers();
    test_soft_reset();
    test_out_of_range();

    check(!changed_off_edge, "reset released asynchronously");
    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end

  // Watchdog
  initial begin
    #2_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
