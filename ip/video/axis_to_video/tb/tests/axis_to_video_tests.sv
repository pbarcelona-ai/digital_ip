// ***************
// Filename: axis_to_video_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the axis_to_video_tb testbench
//   (axis_to_video_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     source      Source
//     wait_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Source: frames f0 .. f0+n-1; optional stall of stall_cycles after pixel stall_at of frame stall_f
  task automatic source(input int f0, input int n);
    for (int f = f0; f < f0 + n; f++)
      for (int i = 0; i < HA * VA; i++) begin
        if (f == stall_f && i == stall_at) begin sv <= 0; repeat (stall_cycles) @(posedge clk); end
        sv <= 0; while ($urandom_range(99) < gap_pct) @(posedge clk);
        sd <= pix(i % HA, i / HA, f); su <= (i == 0); sl <= (i % HA == HA - 1); sv <= 1;
        @(posedge clk); while (!sr) @(posedge clk);
      end
    sv <= 0;
  endtask

  task automatic wait_frame();
    int n; n = nframes; while (nframes == n) @(posedge clk);
  endtask
