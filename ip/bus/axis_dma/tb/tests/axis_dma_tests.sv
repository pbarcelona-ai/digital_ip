// ***************
// Filename: axis_dma_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the axis_dma_tb testbench (axis_dma_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check      Counts an error and prints the message when the condition is
//                false
//     wait_done  Waits until the DUT reports done
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic wait_done(input int bit_done);
    do bfm.read(8'h14, rd); while (rd[bit_done] == 0);
    bfm.write(8'h14, 32'hF00);
  endtask
