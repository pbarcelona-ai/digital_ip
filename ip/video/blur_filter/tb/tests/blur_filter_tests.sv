// ***************
// Filename: blur_filter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the blur_filter_tb testbench
//   (blur_filter_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check      Counts an error and prints the message when the condition is
//                false
//     wr         Register write over the bus
//     rd         Register read over the bus
//     run_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic wr(input int a, input int d);
    bfm.write(8'(a), 32'(d));
  endtask

  task automatic rd(input int a, output logic [31:0] d);
    bfm.read(8'(a), d);
  endtask

  task automatic run_frame(input string what);
    int f0, bad;
    f0 = vid.frames;
    vid.ow = W;
    vid.oh = H;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [23:0] p; // edges to blur / sharpen
      p = ((x / 3 + y / 2) % 2) ? 24'hF0E0D0 : 24'h102030;
      if ($urandom_range(4) == 0) p = $urandom;
      vid.img[y][x] = p;
      mdl.img[y][x] = p;
    end
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    mdl.run(W, H);
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask
