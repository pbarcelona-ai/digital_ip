// ***************
// Filename: blur_sharpen_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the blur_sharpen_tb testbench
//   (blur_sharpen_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check          Counts an error and prints the message when the condition
//                    is false
//     wr             Register write over the bus
//     rd             Register read over the bus
//     program_banks  Kernel banks as programmed (model side)
//     new_image
//     model          Expected output of MODE m
//     compare
//     run_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic wr(input int a, input int d); bfm.write(9'(a), 32'(d)); endtask

  task automatic rd(input int a, output logic [31:0] d); bfm.read(9'(a), d); endtask

  // Kernel banks as programmed (model side)
  task automatic program_banks(input logic [25*32-1:0] b, input int bs, input logic [25*32-1:0] s, input int shs);
    for (int i = 0; i < NN; i++) begin wr(16'h40 + 4 * i, b[i*32 +: 32]); wr(16'hC0 + 4 * i, s[i*32 +: 32]); end
    wr(16'h0C, bs); wr(16'h10, shs);
    kb = b; sb = bs; ks = s; ss = shs;
  endtask

  task automatic new_image();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      logic [23:0] p; p = ((x / 3 + y / 3) % 2) ? 24'hE8D0C0 : 24'h182838;
      if ($urandom_range(5) == 0) p = $urandom;
      src[y][x] = p; vid.img[y][x] = p;
    end
  endtask

  // Expected output of MODE m: stage 1 then stage 2
  task automatic model(input int m);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) mdl.img[y][x] = src[y][x];
    if (m == 0 || m == 3) mdl.set_kernel(kb, sb); else if (m == 1 || m == 2) mdl.set_kernel(ks, ss); else mdl.set_identity();
    mdl.run(W, H); mdl.chain(W, H);
    if (m == 2) mdl.set_kernel(kb, sb); else if (m == 3) mdl.set_kernel(ks, ss); else mdl.set_identity();
    mdl.run(W, H);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) res[y][x] = mdl.out[y][x];
  endtask

  task automatic compare(input string what);
    int bad; bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
      if (vid.out[y][x] !== res[y][x]) begin
        if (bad < 3) $display("  %s (%0d,%0d): %h expected %h", what, x, y, vid.out[y][x], res[y][x]);
        bad++;
      end
    check(bad == 0, $sformatf("%s: %0d pixels differ", what, bad));
  endtask

  task automatic run_frame(input int m, input string what);
    int f0; f0 = vid.frames; vid.ow = W; vid.oh = H;
    vid.send(W, H);
    while (vid.frames < f0 + 1) @(posedge clk);
    model(m); compare(what);
  endtask
