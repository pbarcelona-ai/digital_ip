// ***************
// Filename: tb_scaler_dda.sv
// Author: Paul Barcelona
// Description: Self-checking testbench for scaler_dda.
//   Runs 42 configurations: random output sizes, steps and (negative)
//   offsets with random pipeline stalls. Each emitted coordinate and flag
//   is checked against x = OFFS_X + ox*STEP_X, y = OFFS_Y + oy*STEP_Y;
//   pixel count and busy de-assertion at frame end are verified.
//   Plusargs: +VCD=<file> waveform file, +NO_VCD disables dumping.
// Date: 2026-09-26

`timescale 1ns/1ps
module tb_scaler_dda;
  logic clk = 0; always #5 clk = ~clk;    // 100 MHz clock
  // DUT ports (connected by name)
  logic rst_n = 0, start = 0, adv = 0;
  logic [15:0] out_w, out_h;
  logic [31:0] step_x, step_y;
  logic signed [31:0] offs_x, offs_y;
  logic busy, o_valid, o_sof, o_eol, o_eof;
  logic signed [31:0] o_x, o_y;
  int errors = 0, checks = 0;

  // Device under test
  scaler_dda dut (.*);

  // One frame: start the DDA, advance with random stalls and check each
  // emitted pixel against the closed-form coordinate and flags
  task automatic run(int w, int h, int sx, int sy, int ox0, int oy0, int stall_pct);
    int n = 0, ox = 0, oy = 0;
    @(negedge clk);
    out_w = w; out_h = h; step_x = sx; step_y = sy; offs_x = ox0; offs_y = oy0;
    start = 1;
    @(negedge clk) start = 0;
    while (n < w * h) begin
      adv = ($urandom_range(99, 0) >= stall_pct);
      @(posedge clk); #1;
      if (adv && o_valid) begin
        longint ex = longint'(ox0) + longint'(ox) * sx;
        longint ey = longint'(oy0) + longint'(oy) * sy;
        checks++;
        if (o_x !== 32'(ex) || o_y !== 32'(ey) || o_sof !== (n == 0) ||
            o_eol !== (ox == w - 1) || o_eof !== (n == w * h - 1)) begin
          errors++;
          if (errors < 8) $display("ERROR: px %0d (%0d,%0d) got x=%0h y=%0h sof%0b eol%0b eof%0b",
                                   n, ox, oy, o_x, o_y, o_sof, o_eol, o_eof);
        end
        n++;
        if (ox == w - 1) begin ox = 0; oy++; end else ox++;
      end
      @(negedge clk);
    end
    adv = 1; @(posedge clk); #1;
    checks++;
    if (busy || o_valid) begin errors++; $display("ERROR: DDA still busy/valid after frame"); end
    @(negedge clk) adv = 0;
  endtask

  // Main sequence: two fixed cases, then 40 random configurations
  initial begin
    repeat (3) @(posedge clk); rst_n = 1;
    run(1, 1, 32'h10000, 32'h10000, 0, 0, 0);
    run(7, 3, 32'h8000, 32'h18000, -32'sh4000, 32'sh4000, 30);
    for (int i = 0; i < 40; i++)
      run($urandom_range(40, 1), $urandom_range(30, 1),
          $urandom_range(32'h80000, 32'h1000), $urandom_range(32'h80000, 32'h1000),
          int'($urandom_range(32'h40000, 0)) - 32'h20000,
          int'($urandom_range(32'h40000, 0)) - 32'h20000, $urandom_range(60, 0));
    if (errors == 0) $display("TB_RESULT: PASS  checks=%0d", checks);
    else             $display("TB_RESULT: FAIL  checks=%0d errors=%0d", checks, errors);
    $finish;
  end

  // ---------------------------------------------------------------- waveform dump
  // Writes a VCD of the whole testbench hierarchy.
  //   +VCD=<file>  output file (default tb_scaler_dda.vcd in the working directory)
  //   +NO_VCD      disable dumping (faster, no large file)
  // With the Verilator simulator, compile with --trace (tools/run_sim.sh does).
  initial begin : vcd_dump
    string vcd_file;
    if (!$test$plusargs("NO_VCD")) begin
      if (!$value$plusargs("VCD=%s", vcd_file)) vcd_file = "tb_scaler_dda.vcd";
      $dumpfile(vcd_file);
      $dumpvars(0, tb_scaler_dda);
    end
  end
endmodule
