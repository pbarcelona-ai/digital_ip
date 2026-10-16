// ***************
// Filename: axis_async_bridge_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the AXI-Stream asynchronous
//   bridge. Sends packets of random length with random tkeep, tlast and
//   tuser from a 100 MHz domain to a 43 MHz domain with random stalls on
//   both sides and checks every beat and packet boundary in order. Prints
//   TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module axis_async_bridge_tb;
  logic s_clk = 0, m_clk = 0, s_rst_n = 0, m_rst_n = 0;
  always #5.0 s_clk = ~s_clk;
  always #11.6 m_clk = ~m_clk;
  axis_if #(.DATA_W(32), .USER_W(1), .KEEP_W(4)) m ();
  axis_if #(.DATA_W(32), .USER_W(1), .KEEP_W(4)) s ();
  axis_async_bridge #(
    .DATA_W(32),
    .DEPTH(16),
    .USER_W(1)
  ) dut (
    .s_clk,
    .s_rst_n,
    .s_axis(s),
    .m_clk,
    .m_rst_n,
    .m_axis(m)
  );
  int errors = 0, sent = 0, got = 0;
  localparam int NBEATS = 2000;
  logic [37:0] expq[$];
  int plen;
  // Source: packets of 1..12 beats
  always @(posedge s_clk) if (s_rst_n) begin
    if (s.tvalid && s.tready) begin
      expq.push_back({s.tuser, s.tlast, s.tkeep, s.tdata});
      sent++;
    end
    if (!s.tvalid || s.tready) begin
      if (sent < NBEATS && $urandom_range(0, 9) < 7) begin
        if (plen == 0) plen = $urandom_range(1, 12);
        s.tvalid <= 1;
        s.tdata <= $urandom;
        s.tkeep <= (plen == 1) ? 4'(4'hF >> $urandom_range(0, 3)) : 4'hF;
        s.tlast <= (plen == 1);
        s.tuser <= (plen == 1) ? $urandom_range(0, 1) : 0;
        plen--;
      end else s.tvalid <= 0;
    end
  end
  always @(posedge m_clk) if (m_rst_n) begin
    m.tready <= ($urandom_range(0, 9) < 6);
    if (m.tvalid && m.tready) begin
      logic [37:0] e;
      e = expq.pop_front();
      if ({m.tuser, m.tlast, m.tkeep, m.tdata} !== e) begin
        errors++;
        $display("ERROR beat %0d got %h exp %h", got, {m.tuser, m.tlast, m.tkeep, m.tdata}, e);
        end
      got++;
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("axis_async_bridge_tb.vcd");
      $dumpvars(0, axis_async_bridge_tb);
    end
    s.tvalid = 0;
    m.tready = 0;
    plen = 0;
    s.tdata = 0;
    s.tkeep = 0;
    s.tlast = 0;
    s.tuser = 0;
    repeat (5) @(posedge s_clk);
    s_rst_n = 1;
    m_rst_n = 1;
    wait (got >= NBEATS);
    #500;
    if (sent != got) begin
      errors++;
      $display("ERROR sent %0d got %0d", sent, got);
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #50_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
