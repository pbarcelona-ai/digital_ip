// ***************
// Filename: symbol_overlay_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for symbol_overlay (NOBJ = 4, 24-bit
//   pixels): the structural checks (ID block, registers, pass-through with
//   gaps and back-pressure, COMMIT / STATUS / ENABLE timing with a filled
//   box, FRAME_NUM). Frames are driven and monitored by axis_frame_bfm. Every
//   pixel of every symbol, label and text is compared with the golden model
//   by the cocotb test tb/python/symbol_overlay_tb.py. Prints TEST PASSED on
//   success; +vcd dumps symbol_overlay_tb.vcd. The test tasks are in
//   tests/symbol_overlay_tests.sv (`included).
// Date: 2026-10-20
`timescale 1ns/1ps
module symbol_overlay_tb;
  localparam int NOBJ = 4, NTXT = 4, MAXW = 64, MAXH = 48;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;
  int W = 40, H = 30;

  axil_if #(.ADDR_W(10), .DATA_W(32)) s_axil ();
  axis_if #(.DATA_W(24), .USER_W(1)) m_axis ();
  axis_if #(.DATA_W(24), .USER_W(1)) s_axis ();

  symbol_overlay_top #(
    .NOBJ(NOBJ),
    .NTXT(NTXT)
  ) dut (
    .clk,
    .rst_n,
    .s_axis(s_axis),
    .m_axis(m_axis),
    .s_axil(s_axil)
  );
  axil_bfm #(.ADDR_W(10)) bfm (
    .aclk(clk),
    .*
  );
  axis_frame_bfm #(
    .DW(24),
    .MAXW(MAXW),
    .MAXH(MAXH)
  ) vid (
    .clk,
    .s_tdata(s_axis.tdata),
    .s_tlast(s_axis.tlast),
    .s_tuser(s_axis.tuser),
    .s_tvalid(s_axis.tvalid),
    .s_tready(s_axis.tready),
    .m_tdata(m_axis.tdata),
    .m_tlast(m_axis.tlast),
    .m_tuser(m_axis.tuser),
    .m_tvalid(m_axis.tvalid),
    .m_tready(m_axis.tready)
  );
  `include "symbol_overlay_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("symbol_overlay_tb.vcd");
      $dumpvars(0, symbol_overlay_tb);
    end
    vid.ow = W;
    vid.oh = H;
    repeat (4) @(posedge clk);
    bfm.base = 'h10;                           // the map after the ID block
    rst_n = 1;
    repeat (2) @(posedge clk);
    test_id_block();
    test_registers();
    test_passthrough();
    test_commit();
    test_frame_number();
    check(vid.errors == 0, $sformatf("%0d AXI4-Stream framing errors", vid.errors));
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20ms;
    $display("ERROR: timeout");
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
