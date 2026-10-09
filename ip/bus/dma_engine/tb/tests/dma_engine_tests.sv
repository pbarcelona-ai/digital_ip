// ***************
// Filename: dma_engine_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the dma_engine_tb testbench
//   (dma_engine_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check    Counts an error and prints the message when the condition is
//              false
//     run_dma
//     verify
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run_dma(input [31:0] s, input [31:0] d, input [31:0] len);
    bfm.write(8'h04, s);
    bfm.write(8'h08, d);
    bfm.write(8'h0C, len);
    bfm.write(8'h10, 32'h300);                       // clear flags
    bfm.write(8'h00, 32'h3);                         // start + irq_en
    do bfm.read(8'h10, rd);
    while (rd[8] == 0 && rd[9] == 0);
  endtask

  task automatic verify(input [31:0] s, input [31:0] d, input int words, input string tag);
    for (int i = 0; i < words; i++)
      if (mem.mem[d/4 + i] !== mem.mem[s/4 + i]) begin
        errors++;
        $display("ERROR %s: word %0d dst %h src %h", tag, i, mem.mem[d/4+i], mem.mem[s/4+i]);
        i = words;
        end
  endtask
