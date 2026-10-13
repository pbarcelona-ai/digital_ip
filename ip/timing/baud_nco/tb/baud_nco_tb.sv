// ***************
// Filename: baud_nco_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the baud generator / NCO IP.
//   Verifies the default FCW register, baud tick frequency, tick counter
//   register, and the sine/cosine AXI-Stream samples (phase, offset, gain)
//   against a real-valued model, including random back pressure on tready.
//   Prints TEST PASSED on success. Use +vcd to dump sim/baud_nco_tb.vcd
//   for Surfer.
//   The test tasks are in tests/baud_nco_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module baud_nco_tb;
  localparam real CLK_PERIOD = 10.0;        // 100 MHz
  localparam real PI = 3.14159265358979;

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] m_tdata;
  logic m_tvalid, m_tready, m_tlast;
  logic baud_tick, sq;

  baud_nco_top dut (
    .aclk,
    .aresetn,
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
    .m_axis_tdata(m_tdata),
    .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready),
    .m_axis_tlast(m_tlast),
    .baud_tick_o(baud_tick),
    .sq_o(sq)
  );

  int errors = 0;

  // test tasks: tests/baud_nco_tests.sv
  logic [7:0] reg_base = 8'h10;                   // the register map after the ID block
  logic [1:0] last_bresp;

  // Count baud ticks
  int tick_count;
  always @(posedge aclk) if (baud_tick) tick_count++;

  // Random back pressure generator
  logic bp_enable = 0;
  always @(posedge aclk) m_tready <= bp_enable ? ($urandom_range(0, 9) < 7) : 1'b1;

  // Sample checker: k-th accepted sample must match the phase model
  int  n_samples = 0, chk_enable = 0;
  longint unsigned fcw_m, off_m;
  int gain_m;
  function automatic int model(input longint unsigned k, input bit cosine);
    longint unsigned ph;
    int p10;
    real s;
    ph  = (off_m * 65536 + k * fcw_m) & 64'hFFFF_FFFF;   // 32 bit phase
    p10 = int'(ph >> 22);
    if (cosine) p10 = (p10 + 256) % 1024;
    s = $sin(2.0 * PI * (p10 + 0.5) / 1024.0);
    return int'($floor(s * 32767.0 * gain_m / 32768.0));
  endfunction
  int es, ec, gs, gc;
  always @(posedge aclk) if (chk_enable && m_tvalid && m_tready) begin
    es = model(n_samples, 0);
    ec = model(n_samples, 1);
    gs = $signed(m_tdata[15:0]);
    gc = $signed(m_tdata[31:16]);
    if ((gs - es) > 3 || (es - gs) > 3) begin
      errors++;
      $display("ERROR sin[%0d] got %0d exp %0d", n_samples, gs, es);
      end
    if ((gc - ec) > 3 || (ec - gc) > 3) begin
      errors++;
      $display("ERROR cos[%0d] got %0d exp %0d", n_samples, gc, ec);
      end
    if (m_tlast) begin
      errors++;
      $display("ERROR unexpected tlast");
    end
    n_samples++;
  end

  logic [31:0] rd;
  int hi;
  `include "baud_nco_tests.sv"
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("baud_nco_tb.vcd");
      $dumpvars(0, baud_nco_tb);
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
    tick_count = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (2) @(posedge aclk);

    test_id_block();
    test_default_fcw();
    test_baud_tick();
    test_sine_stream();
    test_backpressure();
    test_square();

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #5_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
