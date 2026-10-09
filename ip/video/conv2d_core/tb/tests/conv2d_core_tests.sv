// ***************
// Filename: conv2d_core_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the conv2d_core_tb testbench
//   (conv2d_core_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     use_kernel
//     new_image
//     compare
//     run_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic use_kernel(input logic [25*32-1:0] kp, input int sh);
    for (int i = 0; i < NN; i++) coef[i*COEF_W +: COEF_W] = kp[i*32 +: COEF_W];
    shift = 5'(sh);
    mdl.set_kernel(kp, sh);
  endtask

  task automatic new_image();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [9:0] p;
      p = ($urandom_range(3) == 0) ? 10'($urandom) : 10'(x * 60 + y * 9);
      vid.img[y][x] = p;
      mdl.img[y][x] = p;
    end
  endtask

  task automatic compare(input string what);
    int bad;
    bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask

  task automatic run_frame(input string what);
    int f0;
    f0 = vid.frames;
    vid.ow = W;
    vid.oh = H;
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    mdl.run(W, H);
    compare(what);
  endtask
