// ***************
// Filename: frame_counter_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for frame_counter (NCH = 3, EVQ = 8,
//   TS_DIV = 3). A reference model (counts, STATUS, event log) follows every
//   marker pulse and register write; the tests compare the DUT's COUNT[i],
//   STATUS, irq_o and logged events with it: register reset values,
//   the ID block, counting, interrupt enable and write-1-to-clear, CLEAR, a marker in the
//   same clock as a clear, a random mix of all of them, the timestamp
//   divider, the event log order (also for markers in one clock and in
//   consecutive clocks), a full log (overflow) and disabled channels.
//   Prints TEST PASSED on success; +vcd dumps
//   frame_counter_tb.vcd. The test tasks are in tests/frame_counter_tests.sv
//   (`included).
// Date: 2026-10-11
`timescale 1ns/1ps
module frame_counter_tb;
  localparam int NCH = 3, EVQ = 8, TS_DIV = 3;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  logic [NCH-1:0] eof_i, irq_o;
  axil_if #(.ADDR_W(8), .DATA_W(32)) s_axil ();

  frame_counter_top #(
    .NCH(NCH),
    .EVQ(EVQ),
    .TS_DIV(TS_DIV)
  ) dut (
    .clk,
    .rst_n,
    .eof_i,
    .irq_o,
    .s_axil(s_axil)
  );
  axil_bfm #(.ADDR_W(8)) bfm (
    .aclk(clk),
    .*
  );

  // ---------------- reference model: updated at every clock from the DUT's own inputs
  int unsigned m_count [NCH];
  logic [NCH-1:0] m_status, m_en, m_ev_en;
  int unsigned m_ev [$];                             // logged events {channel[26:24], count[23:0]}, marker order
  int unsigned m_ev_t [$];                           // and their timestamps
  always @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < NCH; i++) m_count[i] = 0;
      m_status = '0;
      m_en = '0;
      m_ev_en = '0;
    end else begin
      for (int i = 0; i < NCH; i++) if (eof_i[i] && m_ev_en[i]) begin    // the log: marker order, lowest channel first
        int unsigned c;
        c = (dut.u_core.clear && dut.u_core.clear_mask[i]) ? 1 : m_count[i] + 1;
        m_ev.push_back((i << 24) | (c & 24'hFFFFFF));
        m_ev_t.push_back(dut.u_core.ts);
      end
      for (int i = 0; i < NCH; i++) begin
        if (dut.u_core.clear && dut.u_core.clear_mask[i]) m_count[i] = eof_i[i] ? 1 : 0;
        else if (eof_i[i]) m_count[i]++;
      end
      if (dut.u_regs.wr_en && dut.u_regs.wa == 8'h1C) m_status = m_status & ~dut.u_regs.wr_data[NCH-1:0];   // STATUS write 1 to clear
      m_status = m_status | eof_i;
      if (dut.u_regs.wr_en && dut.u_regs.wa == 8'h18) m_en = dut.u_regs.wr_data[NCH-1:0];   // IRQ_EN written
      if (dut.u_regs.wr_en && dut.u_regs.wa == 8'h54) m_ev_en = dut.u_regs.wr_data[NCH-1:0]; // EV_EN written
    end
  end

  `include "frame_counter_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("frame_counter_tb.vcd");
      $dumpvars(0, frame_counter_tb);
    end
    eof_i = '0;
    bfm.base = 'h10;                                 // the map after the ID block
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);
    test_id_block();
    test_registers();
    test_count();
    test_irq();
    test_clear();
    test_clear_collision();
    test_random();
    test_time();
    test_event_order();
    test_event_same_clock();
    test_event_overflow();
    test_event_disabled();
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #2ms;
    $display("ERROR: timeout");
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
