// ***************
// Filename: csi2_tx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the csi2_tx_tb testbench (csi2_tx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check  Counts an error and prints the message when the condition is
//            false
//     run
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic run(input bit y422, input int frames);
    en = 0; yuv = y422;
    repeat (3000) @(posedge pclk);                 // let the links go idle
    for (int g = 0; g < 3; g++) begin nframes_rx[g] = 0; nlines[g] = 0; nfe[g] = 0; end
    en = 1;
    repeat (frames) begin @(posedge vs); end
    @(posedge vs); en = 0;                         // one more vsync closes the last frame
    repeat (3000) @(posedge pclk);
    for (int g = 0; g < 3; g++) begin
      check(nframes_rx[g] == frames && nfe[g] == frames && nlines[g] == frames * VA,
            $sformatf("%s lane set %0d: %0d frames, %0d frame ends, %0d lines; exp %0d, %0d, %0d",
                      y422 ? "YUV422" : "RGB888", g, nframes_rx[g], nfe[g], nlines[g], frames, frames, frames * VA));
    end
    $display("%s: %0d frames of %0dx%0d received on 1, 2 and 4 lanes", y422 ? "YUV422" : "RGB888", frames, HA, VA);
  endtask
