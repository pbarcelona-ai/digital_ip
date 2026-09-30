// ***************
// Filename: axis_checker.sv
// Author: Paul Barcelona
// Description: Passive AXI4-Stream protocol checker with functional coverage, for video
//   streams (tuser = start of frame, tlast = end of line).
//
//   Checks (each violation increments `errors` and prints the rule id)
//     AXIS_X_VALID   tvalid is never X/Z out of reset
//     AXIS_X_PAYLOAD tdata/tuser/tlast are never X/Z while tvalid = 1
//     AXIS_HOLD      once tvalid = 1 it stays 1 until the handshake
//                    (AMBA AXI4-Stream: a source may not retract tvalid)
//     AXIS_STABLE    tdata/tuser/tlast do not change while tvalid && !tready
//   Video framing (only when frame_w > 0 and frame_h > 0 and CHECK_FRAMING=1)
//     AXIS_SOF       tuser = 1 exactly on the first beat of every frame
//     AXIS_EOL       tlast = 1 exactly on beat frame_w-1 of every line
//     AXIS_FRAME     a new frame starts only after frame_w*frame_h beats
//
//   Two equivalent implementations of the handshake rules are provided:
//     * procedural checks (always on; run on every simulator incl. Icarus)
//     * SVA concurrent properties, compiled when `SVA_ON is defined
//       (Verilator --assert, commercial simulators)
//
//   Functional coverage (procedural counters, reported by report()):
//     beats, handshakes after a stall (valid-before-ready), ready-before-valid
//     handshakes, back-to-back beats, idle cycles, stall cycles, longest stall,
//     stall-length buckets (1, 2-3, 4-15, >=16), SOF beats, EOL beats, frames.
//
//   The module never drives anything; bind or instantiate it next to a port.
// Date: 2026-09-26

`timescale 1ns/1ps
module axis_checker #(
  parameter int    DATA_W        = 24,
  parameter string NAME          = "axis",
  parameter bit    CHECK_FRAMING = 1'b1
)(
  input logic              clk,
  input logic              rst_n,
  input logic              tvalid,
  input logic              tready,
  input logic [DATA_W-1:0] tdata,
  input logic              tuser,
  input logic              tlast,
  input int                frame_w,    // 0 disables framing checks
  input int                frame_h
);

  int errors     = 0;      // procedural rule violations
  int sva_errors = 0;      // SVA violations (only with `SVA_ON)

  // coverage counters
  int cov_beats = 0, cov_after_stall = 0, cov_ready_first = 0, cov_b2b = 0;
  int cov_idle = 0, cov_stall_cycles = 0, cov_max_stall = 0;
  int cov_stall_len [4];                 // 1, 2-3, 4-15, >=16
  int cov_sof = 0, cov_eol = 0, cov_frames = 0;

  // history
  logic              p_valid = 1'b0, p_ready = 1'b0, p_hs = 1'b0;
  logic [DATA_W-1:0] p_data;
  logic              p_user, p_last;
  int                stall_run = 0;
  int                fx = 0, fy = 0;
  bit                in_frame = 1'b0;

  initial for (int i = 0; i < 4; i++) cov_stall_len[i] = 0;

  task automatic fail(input string rule, input string msg);
    errors++;
    if (errors <= 10)
      $display("ASSERT %s.%s @%0t: %s", NAME, rule, $time, msg);
  endtask

  wire hs = tvalid && tready;

  always @(posedge clk) begin
    if (!rst_n) begin
      p_valid <= 1'b0; p_hs <= 1'b0; stall_run = 0;
      fx = 0; fy = 0; in_frame = 1'b0;
    end else begin
      // ---------------- protocol rules
      if (((^(tvalid)) === 1'bx)) fail("AXIS_X_VALID", "tvalid is X/Z");
      if (tvalid === 1'b1 && ((^({tdata, tuser, tlast})) === 1'bx))
        fail("AXIS_X_PAYLOAD", "payload X/Z while tvalid");
      if (p_valid && !p_ready && tvalid !== 1'b1)
        fail("AXIS_HOLD", "tvalid dropped before handshake");
      if (p_valid && !p_ready && tvalid === 1'b1 &&
          (tdata !== p_data || tuser !== p_user || tlast !== p_last))
        fail("AXIS_STABLE", "payload changed while stalled");

      // ---------------- framing rules
      if (CHECK_FRAMING && frame_w > 0 && frame_h > 0 && hs) begin
        if (tuser) begin
          if (in_frame) fail("AXIS_FRAME", $sformatf("SOF after %0d lines + %0d beats", fy, fx));
          in_frame = 1'b1; fx = 0; fy = 0;
        end else if (!in_frame)
          fail("AXIS_SOF", "first beat of frame without tuser");
        if (tlast !== (fx == frame_w - 1))
          fail("AXIS_EOL", $sformatf("tlast=%0b at x=%0d (width %0d)", tlast, fx, frame_w));
        if (fx == frame_w - 1) begin
          fx = 0; fy++;
          if (fy == frame_h) begin in_frame = 1'b0; fy = 0; cov_frames++; end
        end else fx++;
      end

      // ---------------- coverage
      if (hs) begin
        cov_beats++;
        if (p_valid && !p_ready) cov_after_stall++;
        if (!p_valid && p_ready) cov_ready_first++;
        if (p_hs) cov_b2b++;
        if (tuser) cov_sof++;
        if (tlast) cov_eol++;
      end
      if (tvalid === 1'b1 && !tready) begin
        cov_stall_cycles++;
        stall_run++;
        if (stall_run > cov_max_stall) cov_max_stall = stall_run;
      end else if (stall_run > 0) begin
        cov_stall_len[(stall_run >= 16) ? 3 : (stall_run >= 4) ? 2 : (stall_run >= 2) ? 1 : 0]++;
        stall_run = 0;
      end
      if (tvalid !== 1'b1) cov_idle++;

      p_valid <= (tvalid === 1'b1);
      p_ready <= tready;
      p_hs    <= hs;
      p_data  <= tdata;
      p_user  <= tuser;
      p_last  <= tlast;
    end
  end

  // number of coverage bins hit out of the bins that matter for a stream
  function automatic int bins_hit();
    return (cov_beats > 0) + (cov_after_stall > 0) + (cov_ready_first > 0) + (cov_b2b > 0)
         + (cov_idle > 0) + (cov_stall_len[0] > 0) + (cov_stall_len[1] > 0)
         + (cov_stall_len[2] > 0) + (cov_sof > 0) + (cov_eol > 0);
  endfunction
  localparam int BINS = 10;

  task automatic report();
    $display("COVERAGE %-10s beats=%0d frames=%0d sof=%0d eol=%0d b2b=%0d after_stall=%0d ready_first=%0d idle=%0d",
             NAME, cov_beats, cov_frames, cov_sof, cov_eol, cov_b2b, cov_after_stall,
             cov_ready_first, cov_idle);
    $display("COVERAGE %-10s stall_cycles=%0d max_stall=%0d stall_len[1|2-3|4-15|16+]=%0d|%0d|%0d|%0d  bins %0d/%0d  assertion_errors=%0d sva_errors=%0d",
             NAME, cov_stall_cycles, cov_max_stall, cov_stall_len[0], cov_stall_len[1],
             cov_stall_len[2], cov_stall_len[3], bins_hit(), BINS, errors, sva_errors);
  endtask

`ifdef SVA_ON
  function automatic void sva_fail(input string rule);
    sva_errors++;
    if (sva_errors <= 10) $display("SVA %s.%s @%0t", NAME, rule, $time);
  endfunction

  // ---------------- SVA equivalents of the handshake rules
  property p_hold;
    @(posedge clk) disable iff (!rst_n) (tvalid && !tready) |=> tvalid;
  endproperty
  property p_stable;
    @(posedge clk) disable iff (!rst_n)
      (tvalid && !tready) |=> ($stable(tdata) && $stable(tuser) && $stable(tlast));
  endproperty
  property p_known;
    @(posedge clk) disable iff (!rst_n) !$isunknown(tvalid);
  endproperty
  a_hold:   assert property (p_hold)   else sva_fail("AXIS_HOLD");
  a_stable: assert property (p_stable) else sva_fail("AXIS_STABLE");
  a_known:  assert property (p_known)  else sva_fail("AXIS_X_VALID");
  c_stall:  cover property (@(posedge clk) disable iff (!rst_n) $past(tvalid && !tready) && tvalid && tready);
  c_b2b:    cover property (@(posedge clk) disable iff (!rst_n) $past(tvalid && tready) && tvalid && tready);
`endif

endmodule
