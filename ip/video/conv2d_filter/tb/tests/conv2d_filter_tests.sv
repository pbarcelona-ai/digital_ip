// ***************
// Filename: conv2d_filter_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the conv2d_filter_tb testbench
//   (conv2d_filter_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check           Counts an error and prints the message when the
//                     condition is false
//     wr              Register write over the bus
//     rd              Register read over the bus
//     program_kernel  Program a kernel (registers and model)
//     new_image
//     run_frame       Stream one frame and compare it with the model's current
//                     kernel
//     compare
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic wr(input int a, input int d); bfm.write(8'(a), 32'(d)); endtask

  task automatic rd(input int a, output logic [31:0] d); bfm.read(8'(a), d); endtask

  // Program a kernel (registers and model)
  task automatic program_kernel(input logic [25*32-1:0] kp, input int sh);
    for (int i = 0; i < NN; i++) wr(16'h40 + 4 * i, kp[i*32 +: 32]);
    wr(16'h08, sh);
  endtask

  task automatic new_image();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [23:0] p; p = {8'($urandom), 8'(x * 19 + y * 7), 8'((x < W / 2) ? 8'd0 : 8'd255)};
      if ($urandom_range(9) == 0) p = $urandom;
      vid.img[y][x] = p; mdl.img[y][x] = p;
    end
  endtask

  // Stream one frame and compare it with the model's current kernel
  task automatic run_frame(input string what);
    int f0, bad; f0 = vid.frames; vid.ow = W; vid.oh = H;
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    mdl.run(W, H); compare(what);
  endtask

  task automatic compare(input string what);
    int bad; bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== mdl.out[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], mdl.out[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask
