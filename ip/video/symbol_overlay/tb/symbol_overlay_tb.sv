// ***************
// Filename: symbol_overlay_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for symbol_overlay (NOBJ = 4, 24-bit
//   pixels). Frames are driven and monitored by axis_frame_bfm (random
//   input gaps and output back-pressure where a test asks for them); every
//   output frame is compared with track_ref's drawing model of the objects
//   the testbench expects to be active for that frame (the last COMMIT
//   before the frame start, CTRL.ENABLE at the frame start). Tests:
//   registers, pass-through and latency, every shape / dash / width /
//   blend combination, object priority, COMMIT timing (also in the middle
//   of a frame), boxes beyond the frame edge, random objects with
//   back-pressure; text objects (every scale, backdrop, lengths 0 and 16,
//   lowercase, over objects, clipped at the frame edge, COMMIT timing,
//   random texts). Prints TEST PASSED on success; +vcd dumps
//   symbol_overlay_tb.vcd. The test tasks are in tests/symbol_overlay_tests.sv
//   (`included).
// Date: 2026-10-11
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
  track_ref #(
    .MAXW(MAXW),
    .MAXH(MAXH),
    .NOBJ(NOBJ)
  ) mdl ();

  // expected state: objects written (w_obj), committed and active for the next frame (a_obj)
  logic [127:0] w_obj [NOBJ];
  logic [127:0] a_obj [NOBJ];
  logic [95:0] w_txt [NTXT];                         // texts written / active {COLOR, POS, CTRL}
  logic [95:0] a_txt [NTXT];
  logic [127:0] w_chr [NTXT];                        // and their characters
  logic [127:0] a_chr [NTXT];
  bit w_en = 0, pending = 0;
  int a_fnum = 0, set_fnum = 0;                      // frame number shown; FRAME_NUM written for the next frame
  bit fnum_pend = 0;

  `include "symbol_overlay_tests.sv"

  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("symbol_overlay_tb.vcd");
      $dumpvars(0, symbol_overlay_tb);
    end
    for (int i = 0; i < NOBJ; i++) begin
      w_obj[i] = '0;
      a_obj[i] = '0;
    end
    for (int j = 0; j < NTXT; j++) begin
      w_txt[j] = '0;
      a_txt[j] = '0;
      w_chr[j] = '0;
      a_chr[j] = '0;
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
    test_shapes();
    test_priority();
    test_commit();
    test_edges();
    test_random();
    test_text();
    test_text_commit();
    test_text_random();
    test_frame_number();
    test_circle();
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
