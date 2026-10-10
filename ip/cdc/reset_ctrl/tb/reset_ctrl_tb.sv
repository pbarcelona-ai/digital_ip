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
  `include "reset_ctrl_tests.sv"

  logic [31:0] rd;
  logic changed_off_edge = 0;
  // Output must only de-assert on a clock edge (synchronous release)
  always @(posedge rst_o[0]) if ($time % 10000 != 0 && $realtime > 200)
    if (arst_i == 1'b1 && aclk !== 1'b1) changed_off_edge = 1;

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

    // ---- Test 1: power-up async reset and synchronous release ----
    arst_i = 0; // asserted before any clock edge
    #3;
    check(rst_o == '0, "outputs not asserted asynchronously");
    #47 arst_i = 1;                       // release (active low input)
    repeat (3) @(posedge aclk);
    check(rst_o == '0, "reset released too early (sync stages)");
    repeat (4 + HOLD) @(posedge aclk);
    check(rst_o == '1, "reset did not release after stretch");
    check(bus_rst_n == 1'b1, "bus reset stuck");

    // ---- Test 2: sub-clock glitch is stretched to >= HOLD cycles ----
    #(CLK_PERIOD*3 + 2.5);
    arst_i = 0; // 1 ns glitch
    #1.0 arst_i = 1;
    #0.1 check(rst_o == '0, "glitch not caught asynchronously");
    measure_low();
    check(low_cycles >= HOLD, $sformatf("glitch pulse %0d < HOLD %0d", low_cycles, HOLD));
    repeat (8) @(posedge aclk);

    // ---- Test 3: register access ----
    axil_read(8'h04, rd);
    check(rd == HOLD, "HOLD default readback");
    axil_write(8'h04, 32'd8);
    axil_read(8'h04, rd);
    check(rd == 8, "HOLD write/readback");
    axil_read(8'h08, rd);
    check(rd[1] == 1'b1, "sticky event flag should be set by glitch");
    axil_write(8'h08, 32'h2);             // W1C
    axil_read(8'h08, rd);
    check(rd[1] == 1'b0, "sticky flag not cleared by W1C");
    axil_read(8'h0C, rd);
    check(rd >= 1, "event counter should have counted the glitch");
    begin
      logic [31:0] cnt0;
      cnt0 = rd;
      // ---- Test 4: software reset ----
      axil_write(8'h00, 32'd1);
      wait (rst_o[0] == 1'b0);
      check(rst_o == '0, "all copies must assert together");
      measure_low();
      check(low_cycles >= 8, "soft reset shorter than HOLD");
      repeat (6) @(posedge aclk);
      axil_read(8'h0C, rd);
      check(rd == cnt0 + 1, "event counter did not increment on soft reset");
      axil_read(8'h08, rd);
      check(rd[1] == 1'b1 && rd[0] == 1'b0, "status after soft reset");
    end
    // out-of-range access returns SLVERR
    axil_read(8'h40, rd);
    check(rresp == 2'b10, "expected SLVERR for out-of-range read");

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
