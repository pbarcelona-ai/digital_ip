// ***************
// Filename: axis_to_video_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for axis_to_video with a
//   vid_timing_gen in genlock mode. A source streams frames whose pixels
//   are a function of (x, y, frame) with random gaps. Checks:
//     - frame lock: after the black frames output before the source starts,
//       every output frame is a complete, pixel-exact input frame, in
//       order, and the display waits (genlock) for the bursty source;
//     - underflow: a source that stalls mid-frame gives underflow_o, black
//       for the rest of that frame, and the next frame is again exact;
//       (vvp 14-devel crashes on an early return from nested loops in a
//       function, so frame_id() avoids it)
//     - test pattern: eight colour bars, input discarded.
//   Prints TEST PASSED on success.
//   The test tasks are in tests/axis_to_video_tests.sv (`included).
// Date: 2026-10-01
`timescale 1ns/1ps
module axis_to_video_tb;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  int errors = 0;

  localparam int HA = 32, VA = 8;
  logic tpg, src_rdy;
  logic de, hs, vs, sof, eol, vbl, wt;
  logic [15:0] x, y;
  vid_timing_gen u_vtg (
    .clk,
    .rst_n,
    .enable_i(1'b1),
    .h_active_i(16'(HA)),
    .h_fp_i(16'd4),
    .h_sync_i(16'd6),
    .h_bp_i(16'd10),
    .v_active_i(16'(VA)),
    .v_fp_i(16'd1),
    .v_sync_i(16'd2),
    .v_bp_i(16'd2),
    .hs_pol_i(1'b1),
    .vs_pol_i(1'b1),
    .lock_en_i(1'b1),
    .src_ready_i(src_rdy),
    .lock_max_i(16'd400),
    .de_o(de),
    .hs_o(hs),
    .vs_o(vs),
    .x_o(x),
    .y_o(y),
    .sof_o(sof),
    .eol_o(eol),
    .vblank_o(vbl),
    .waiting_o(wt)
  );

  logic [23:0] sd;
  logic sl, su, sv, sr;
  logic [23:0] rgb;
  logic de_o, hs_o, vs_o, locked, uflow;
  axis_to_video #(.PIX_W(24), .FIFO_DEPTH(64)) dut (
    .clk,
    .rst_n,
    .tpg_en_i(tpg),
    .start_level_i(16'd8),
    .h_active_i(16'(HA)),
    .s_axis_tdata(sd),
    .s_axis_tlast(sl),
    .s_axis_tuser(su),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .de_i(de),
    .hs_i(hs),
    .vs_i(vs),
    .sof_i(sof),
    .vblank_i(vbl),
    .rgb_o(rgb),
    .de_o(de_o),
    .hs_o(hs_o),
    .vs_o(vs_o),
    .src_ready_o(src_rdy),
    .locked_o(locked),
    .underflow_o(uflow)
  );

  function automatic logic [23:0] pix(input int px, input int py, input int f);
    return {8'(f * 31 + 1), 8'(py), 8'(px)};
  endfunction

  // used by task source (tests/axis_to_video_tests.sv)
  int gap_pct = 20, stall_f = -1, stall_at = 0, stall_cycles = 0;

  // Sink: capture output frames (output is one clock after the timing)
  logic [23:0] cap [VA][HA];
  int cx, cy, nframes = 0, nunder = 0;
  logic sof_q;
  always @(posedge clk) begin
    sof_q <= sof;
    if (uflow) nunder++;
    if (de_o) begin
      if (sof_q) begin
        cx = 0;
        cy = 0;
      end
      cap[cy][cx] = rgb;
      cx++;
      if (cx == HA) begin
        cx = 0;
        cy++;
        if (cy == VA) nframes++;
      end
    end
  end
  // test tasks: tests/axis_to_video_tests.sv
  `include "axis_to_video_tests.sv"
  // Which source frame (if any) is in cap, and is it exact
  function automatic int frame_id();
    int f, ok;
    logic [23:0] p0, e;
    logic [7:0] tag;
    p0 = cap[0][0];
    tag = p0[23:16];
    f = (int'(tag) - 1) / 31;
    ok = 1;
    for (int yy = 0; yy < VA; yy++) for (int xx = 0; xx < HA; xx++) begin
      e = pix(xx, yy, f);
      if (cap[yy][xx] != e) ok = 0;
    end
    frame_id = ok ? f : -1;
  endfunction

  initial begin
    #20ms;
    $display("ERROR: simulation timeout");
    $display("TEST FAILED");
    $finish;
  end

  initial begin
    int last;
    if ($test$plusargs("vcd")) begin
      $dumpfile("axis_to_video_tb.vcd");
      $dumpvars(0, axis_to_video_tb);
    end
    tpg = 0;
    sv = 0;
    su = 0;
    sl = 0;
    sd = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;

    // ---- frame lock: 5 frames, slow bursty source (display waits through genlock)
    gap_pct = 20;
    fork source(0, 5); join_none
    // The display starts at power-up, before the source: frames are black
    // until the first input frame is ready, then every frame must follow.
    do wait_frame();
    while (frame_id() < 0);
    check(frame_id() == 0, $sformatf("first locked frame is %0d", frame_id()));
    last = frame_id();
    repeat (4) begin
      int f;
      wait_frame();
      f = frame_id();
      check(f == last + 1, $sformatf("frame lock: got frame %0d after %0d", f, last));
      last = f;
    end
    check(nunder == 0, $sformatf("%0d underflows with a well-behaved source", nunder));
    $display("frame lock: 5 frames pixel-exact and in order, no underflow");

    // ---- underflow: frame 6 stalls in its 3rd line for longer than a line
    wait fork;
    stall_f = 6;
    stall_at = 2 * HA + 5;
    stall_cycles = 400;
    gap_pct = 0;
    fork source(5, 4); join_none
    begin
      bit saw_black;
      int got [4];
      saw_black = 0;
      for (int k = 0; k < 4; k++) begin
        wait_frame();
        got[k] = frame_id();
        if (got[k] < 0 && cap[VA-1][HA-1] == 24'h0 && cap[0][0] == pix(0, 0, 6)) saw_black = 1;
      end
      check(nunder >= 1, "no underflow reported");
      check(saw_black, "the stalled frame was not blacked out after the underflow");
      check(got[0] == 5 && got[1] == -1 && got[2] == 7 || got[0] == 4 && got[1] == 5 && got[2] == -1 && got[3] == 7,
            $sformatf("expected 5, blacked-out 6, then 7: frames %0d %0d %0d %0d", got[0], got[1], got[2], got[3]));
      $display("underflow: frames %0d %0d %0d %0d (-1 = blacked out), %0d underflow pulse(s)", got[0], got[1], got[2], got[3], nunder);
    end
    wait fork;

    // ---- test pattern
    tpg = 1;
    wait_frame();
    wait_frame();
    begin
      logic [23:0] bars [8];
      bars = '{24'hFFFFFF, 24'h00FFFF, 24'hFFFF00, 24'h00FF00, 24'hFF00FF, 24'h0000FF, 24'hFF0000, 24'h000000};
      for (int yy = 0; yy < VA; yy++) for (int xx = 0; xx < HA; xx++)
        check(cap[yy][xx] == bars[xx / (HA / 8)], $sformatf("test pattern (%0d,%0d) = %h", xx, yy, cap[yy][xx]));
    end
    $display("test pattern: 8 colour bars");
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
