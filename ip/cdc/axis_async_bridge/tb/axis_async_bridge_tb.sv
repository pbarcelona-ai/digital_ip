// ***************
// Filename: axis_async_bridge_tb.sv
// Author: Paul Barcelona
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
  logic [31:0] s_tdata, m_tdata; logic [3:0] s_tkeep, m_tkeep; logic s_tlast, m_tlast;
  logic [0:0] s_tuser, m_tuser; logic s_tvalid, s_tready, m_tvalid, m_tready;
  axis_async_bridge #(.DATA_W(32), .DEPTH(16), .USER_W(1)) dut (
    .s_clk, .s_rst_n, .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tlast(s_tlast),
    .s_axis_tuser(s_tuser), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready),
    .m_clk, .m_rst_n, .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
    .m_axis_tuser(m_tuser), .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready));
  int errors = 0, sent = 0, got = 0; localparam int NBEATS = 2000;
  logic [37:0] expq[$];
  int plen;
  // Source: packets of 1..12 beats
  always @(posedge s_clk) if (s_rst_n) begin
    if (s_tvalid && s_tready) begin expq.push_back({s_tuser, s_tlast, s_tkeep, s_tdata}); sent++; end
    if (!s_tvalid || s_tready) begin
      if (sent < NBEATS && $urandom_range(0, 9) < 7) begin
        if (plen == 0) plen = $urandom_range(1, 12);
        s_tvalid <= 1; s_tdata <= $urandom; s_tkeep <= (plen == 1) ? 4'(4'hF >> $urandom_range(0, 3)) : 4'hF;
        s_tlast <= (plen == 1); s_tuser <= (plen == 1) ? $urandom_range(0, 1) : 0;
        plen--;
      end else s_tvalid <= 0;
    end
  end
  always @(posedge m_clk) if (m_rst_n) begin
    m_tready <= ($urandom_range(0, 9) < 6);
    if (m_tvalid && m_tready) begin
      logic [37:0] e; e = expq.pop_front();
      if ({m_tuser, m_tlast, m_tkeep, m_tdata} !== e) begin
        errors++; $display("ERROR beat %0d got %h exp %h", got, {m_tuser, m_tlast, m_tkeep, m_tdata}, e); end
      got++;
    end
  end
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("axis_async_bridge_tb.vcd"); $dumpvars(0, axis_async_bridge_tb); end
    s_tvalid = 0; m_tready = 0; plen = 0; s_tdata = 0; s_tkeep = 0; s_tlast = 0; s_tuser = 0;
    repeat (5) @(posedge s_clk); s_rst_n = 1; m_rst_n = 1;
    wait (got >= NBEATS); #500;
    if (sent != got) begin errors++; $display("ERROR sent %0d got %0d", sent, got); end
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #50_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
