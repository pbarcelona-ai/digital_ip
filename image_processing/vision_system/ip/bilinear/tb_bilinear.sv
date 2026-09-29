// ***************
// Filename: tb_bilinear.sv
// Author: Paul Barcelona
// Description: Self-checking standalone testbench for bilinear.
// Verifies the 4 corner cases, exact center, general non-
// degenerate cases, 3-cycle pipeline latency, and correct
// bubble (no spurious output) behavior.
// Date: September 26, 2026
// ***************
// =============================================================================
// tb_bilinear.sv
//
// Self-checking testbench for bilinear.sv (reusable IP). Depends only on
// barrel_pkg.sv for PIX_W.
//
// Checks each case against an independent reference computation (the same
// weighted-average formula, written fresh here rather than calling the
// RTL's own blend_chan function), covering:
//   - all 4 corner cases (fx,fy at the extremes -- output should equal,
//     or come extremely close to, the corresponding corner pixel)
//   - the exact center (fx=fy=128 -- output should be very close to the
//     unweighted average of all 4 corners)
//   - several general (non-degenerate) fx/fy/corner combinations
//   - pipeline latency (exactly 3 cycles from valid_in to valid_out)
//   - valid_in de-asserted -> valid_out de-asserted 2 cycles later (no
//     spurious output from a bubble)
// =============================================================================
`timescale 1ns/1ps
import barrel_pkg::*;

module tb_bilinear;
  logic clk = 0, rst_n = 0;
  logic valid_in;
  logic [7:0] fx, fy;
  logic [PIX_W-1:0] tl, tr, bl, br;
  logic valid_out;
  logic [PIX_W-1:0] pixel_out;

  bilinear dut (.clk, .rst_n, .valid_in, .fx, .fy, .tl, .tr, .bl, .br, .valid_out, .pixel_out);

  always #5 clk = ~clk;

  int checks, fails;

  function automatic logic [7:0] ref_chan(input logic [7:0] c00, c10, c01, c11,
                                            input logic [7:0] fx_i, fy_i);
    logic [16:0] w00, w10, w01, w11;
    logic [26:0] acc;
    begin
      w00 = (9'd256 - fx_i) * (9'd256 - fy_i);
      w10 = fx_i * (9'd256 - fy_i);
      w01 = (9'd256 - fx_i) * fy_i;
      w11 = fx_i * fy_i;
      acc = c00*w00 + c10*w10 + c01*w01 + c11*w11 + 27'd32768;
      return acc[23:16];
    end
  endfunction

  task automatic check(input string label, input logic [PIX_W-1:0] TL, TR, BL, BR,
                        input logic [7:0] FX, FY);
    logic [PIX_W-1:0] expected;
    begin
      expected[23:16] = ref_chan(TL[23:16], TR[23:16], BL[23:16], BR[23:16], FX, FY);
      expected[15:8]  = ref_chan(TL[15:8],  TR[15:8],  BL[15:8],  BR[15:8],  FX, FY);
      expected[7:0]   = ref_chan(TL[7:0],   TR[7:0],   BL[7:0],   BR[7:0],   FX, FY);

      @(posedge clk);
      tl <= TL; tr <= TR; bl <= BL; br <= BR; fx <= FX; fy <= FY; valid_in <= 1'b1;
      @(posedge clk);
      valid_in <= 1'b0;
      @(posedge clk);
      @(posedge clk);   // LATENCY=3: valid_out should now be asserted
      #1;
      checks = checks + 1;
      if (!valid_out) begin
        $display("[%s] FAIL: valid_out not asserted at expected 3-cycle latency", label);
        fails = fails + 1;
      end else if (pixel_out !== expected) begin
        $display("[%s] FAIL: pixel_out=0x%06h expected=0x%06h (TL=%06h TR=%06h BL=%06h BR=%06h fx=%0d fy=%0d)",
                   label, pixel_out, expected, TL, TR, BL, BR, FX, FY);
        fails = fails + 1;
      end else begin
        $display("[%s] PASS: pixel_out=0x%06h", label, pixel_out);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    checks = 0; fails = 0;
    valid_in = 0; fx = 0; fy = 0; tl = 0; tr = 0; bl = 0; br = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- corner cases: fx=fy=0 -> exactly TL --------------------------
    check("corner_TL", 24'h10_20_30, 24'h80_80_80, 24'hA0_A0_A0, 24'hFF_FF_FF, 8'd0, 8'd0);
    // fx=255 (not quite 1.0 -- 255/256), fy=0: overwhelmingly TR, tiny TL residual
    check("corner_near_TR", 24'h10_20_30, 24'h80_80_80, 24'hA0_A0_A0, 24'hFF_FF_FF, 8'd255, 8'd0);
    check("corner_near_BL", 24'h10_20_30, 24'h80_80_80, 24'hA0_A0_A0, 24'hFF_FF_FF, 8'd0, 8'd255);
    check("corner_near_BR", 24'h10_20_30, 24'h80_80_80, 24'hA0_A0_A0, 24'hFF_FF_FF, 8'd255, 8'd255);

    // ---- exact center: average of all four corners ---------------------
    check("center", 24'h00_00_00, 24'hFF_FF_FF, 24'hFF_FF_FF, 24'h00_00_00, 8'd128, 8'd128);

    // ---- general, non-degenerate cases -----------------------------------
    check("general_1", 24'h11_22_33, 24'h44_55_66, 24'h77_88_99, 24'hAA_BB_CC, 8'd64, 8'd192);
    check("general_2", 24'hFF_00_80, 24'h00_FF_40, 24'h80_40_FF, 24'h20_60_A0, 8'd37, 8'd211);
    check("general_3", 24'h00_00_00, 24'h00_00_00, 24'h00_00_00, 24'hFF_FF_FF, 8'd200, 8'd200); // corner weight isolation

    // ---- latency / bubble behavior ---------------------------------------
    // Edge A: valid_in<=1 driven (visible starting next edge).
    // Edge B: valid_in<=0 driven (also where stage A samples valid_in=1,
    //         so vA becomes 1 right after edge B).
    // Edge C: stage B1 samples vA=1, so vB1=1 right after edge C
    //         (valid_out must still be 0).
    // Edge D: stage B2 samples vB1=1, so valid_out=1 right after edge D --
    //         exactly 3 edges after edge A, the documented LATENCY=3.
    // Edge E: valid_in was only a 1-cycle pulse, so valid_out falls back
    //         to 0 right after edge E.
    @(posedge clk);   // edge A
    tl <= 24'h123456; tr <= 24'h123456; bl <= 24'h123456; br <= 24'h123456;
    fx <= 8'd0; fy <= 8'd0; valid_in <= 1'b1;
    @(posedge clk);   // edge B
    valid_in <= 1'b0;   // single 1-cycle pulse, no more valid_in after this
    #1;
    checks = checks + 1;
    if (valid_out) begin
      $display("[latency_check] FAIL: valid_out asserted too early (right after edge B)");
      fails = fails + 1;
    end else begin
      $display("[latency_check after-edge-B-still-low] PASS");
    end
    @(posedge clk);   // edge C
    #1;
    checks = checks + 1;
    if (valid_out) begin
      $display("[latency_check] FAIL: valid_out asserted too early (right after edge C)");
      fails = fails + 1;
    end else begin
      $display("[latency_check after-edge-C-still-low] PASS");
    end
    @(posedge clk);   // edge D -- the LATENCY=3 point
    #1;
    checks = checks + 1;
    if (!valid_out || pixel_out !== 24'h123456) begin
      $display("[latency_check] FAIL: expected valid_out=1, pixel_out=0x123456 right after edge D (3-edge latency), got valid_out=%0d pixel_out=0x%06h",
                 valid_out, pixel_out);
      fails = fails + 1;
    end else begin
      $display("[latency_check after-edge-D-correct-3cyc-latency] PASS");
    end
    @(posedge clk);   // edge E -- pulse should have fallen back to 0
    #1;
    checks = checks + 1;
    if (valid_out) begin
      $display("[latency_check] FAIL: valid_out still high right after edge E (a single 1-cycle valid_in pulse leaked through as a longer/repeated output)");
      fails = fails + 1;
    end else begin
      $display("[latency_check after-edge-E-bubble-does-not-repeat] PASS");
    end

    $display("=== bilinear self-check: %0d/%0d checks passed ===", checks - fails, checks);
    if (fails == 0) $display(">>> PASS <<<");
    else             $display(">>> FAIL (%0d mismatches) <<<", fails);
    $finish;
  end

  // Optional waveform dump: compile with -DDUMP_VCD (the run scripts do
  // this when VCD=1). View with synth/view_waves.sh (Surfer).
`ifdef DUMP_VCD
  initial begin
    $dumpfile("waves.vcd");
    $dumpvars(0, tb_bilinear);
  end
`endif
endmodule
