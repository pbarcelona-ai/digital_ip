// ***************
// Filename: baud_nco_tb.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for the baud generator / NCO IP.
//   Verifies the default FCW register, baud tick frequency, tick counter
//   register, and the sine/cosine AXI-Stream samples (phase, offset, gain)
//   against a real-valued model, including random back pressure on tready.
//   Prints TEST PASSED on success. Use +vcd to dump sim/baud_nco_tb.vcd
//   for Surfer.
// Date: 2026-09-29
`timescale 1ns/1ps
module baud_nco_tb;
  localparam real CLK_PERIOD = 10.0;        // 100 MHz
  localparam real PI = 3.14159265358979;

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr; logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [31:0] m_tdata; logic m_tvalid, m_tready, m_tlast;
  logic baud_tick, sq;

  baud_nco_top dut (
    .aclk, .aresetn,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
    .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
    .baud_tick_o(baud_tick), .sq_o(sq));

  int errors = 0;
  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR @%0t: %s", $time, msg); end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge aclk); #1;
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1; bready = 1;
    fork
      begin wait (awready); @(posedge aclk); #1 awvalid = 0; end
      begin wait (wready);  @(posedge aclk); #1 wvalid = 0;  end
    join
    wait (bvalid); @(posedge aclk); #1;
  endtask
  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1; rready = 1;
    wait (arready); @(posedge aclk); #1 arvalid = 0;
    wait (rvalid); d = rdata; @(posedge aclk); #1;
  endtask

  // Count baud ticks
  int tick_count;
  always @(posedge aclk) if (baud_tick) tick_count++;

  // Random back pressure generator
  logic bp_enable = 0;
  always @(posedge aclk) m_tready <= bp_enable ? ($urandom_range(0, 9) < 7) : 1'b1;

  // Sample checker: k-th accepted sample must match the phase model
  int  n_samples = 0, chk_enable = 0;
  longint unsigned fcw_m, off_m; int gain_m;
  function automatic int model(input longint unsigned k, input bit cosine);
    longint unsigned ph; int p10; real s;
    ph  = (off_m * 65536 + k * fcw_m) & 64'hFFFF_FFFF;   // 32 bit phase
    p10 = int'(ph >> 22);
    if (cosine) p10 = (p10 + 256) % 1024;
    s = $sin(2.0 * PI * (p10 + 0.5) / 1024.0);
    return int'($floor(s * 32767.0 * gain_m / 32768.0));
  endfunction
  int es, ec, gs, gc;
  always @(posedge aclk) if (chk_enable && m_tvalid && m_tready) begin
    es = model(n_samples, 0); ec = model(n_samples, 1);
    gs = $signed(m_tdata[15:0]); gc = $signed(m_tdata[31:16]);
    if ((gs - es) > 3 || (es - gs) > 3) begin
      errors++; $display("ERROR sin[%0d] got %0d exp %0d", n_samples, gs, es); end
    if ((gc - ec) > 3 || (ec - gc) > 3) begin
      errors++; $display("ERROR cos[%0d] got %0d exp %0d", n_samples, gc, ec); end
    if (m_tlast) begin errors++; $display("ERROR unexpected tlast"); end
    n_samples++;
  end

  logic [31:0] rd;
  int hi;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("baud_nco_tb.vcd"); $dumpvars(0, baud_nco_tb);
    end
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; tick_count = 0;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);

    // ---- Test 1: default FCW = 115200 * 16 at 100 MHz ----
    axil_read(8'h04, rd);
    check(rd == 32'd79164837, $sformatf("default FCW %0d", rd));
    axil_read(8'h00, rd); check(rd[0] == 1, "enabled after reset");

    // ---- Test 2: baud tick frequency, 16 MHz tick (1 Mbaud x16) ----
    axil_write(8'h14, 0);                    // clear tick counter
    axil_write(8'h04, 32'd687194767);
    repeat (5) @(posedge aclk); tick_count = 0;
    repeat (10000) @(posedge aclk);
    check(tick_count >= 1599 && tick_count <= 1601,
          $sformatf("tick count %0d, expected 1600", tick_count));
    axil_read(8'h14, rd);
    check(rd >= 1599, $sformatf("TICK_COUNT reg %0d", rd));

    // ---- Test 3: sine/cosine stream, quarter cycle offset, gain 0.5 ----
    fcw_m = 32'h0400_0000 + 32'h0000_1234; off_m = 16'h4000; gain_m = 16384;
    axil_write(8'h00, 32'd0);                // stop
    axil_write(8'h04, fcw_m);
    axil_write(8'h08, off_m);
    axil_write(8'h0C, gain_m);
    n_samples = 0; chk_enable = 1;
    axil_write(8'h00, 32'h7);                // en | stream_en | phase reset
    repeat (600) @(posedge aclk);
    check(n_samples >= 590, $sformatf("only %0d samples in 600 clocks", n_samples));

    // ---- Test 4: random back pressure, full gain ----
    axil_write(8'h00, 32'd0);
    chk_enable = 0; repeat (4) @(posedge aclk);
    gain_m = 32767; off_m = 0; fcw_m = 32'h0123_4567;
    axil_write(8'h04, fcw_m); axil_write(8'h08, off_m); axil_write(8'h0C, gain_m);
    bp_enable = 1; n_samples = 0; chk_enable = 1;
    axil_write(8'h00, 32'h7);
    repeat (2000) @(posedge aclk);
    check(n_samples > 1000 && n_samples < 1600, $sformatf("bp samples %0d", n_samples));

    // ---- Test 5: square wave and register readback ----
    chk_enable = 0; bp_enable = 0; axil_write(8'h00, 32'h1);
    axil_write(8'h04, 32'h4000_0000);        // f = clk/4
    repeat (4) @(posedge aclk);
    hi = 0; repeat (400) begin @(posedge aclk); hi += sq; end
    check(hi >= 195 && hi <= 205, $sformatf("square duty %0d/400", hi));
    axil_read(8'h00, rd); check(rd[2] == 0, "phase reset bit must self clear");

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #5_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
