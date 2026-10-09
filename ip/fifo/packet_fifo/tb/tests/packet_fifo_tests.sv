// ***************
// Filename: packet_fifo_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the packet_fifo_tb testbench
//   (packet_fifo_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     send_packet  Writer
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  // writer: one packet at a time; model decides acceptance from the FIFO occupancy visible in the DUT
  task automatic send_packet(input int len, input bit bad);
    int free_words, stored; bit will_drop;
    pend.delete();
    for (int i = 0; i < len; i++) begin
      @(posedge clk); #1 sv = 1; sd = $urandom; sl = (i == len - 1); sb = bad && (i == len - 1);
      pend.push_back({sl, sd});
    end
    @(posedge clk); #1 sv = 0; sl = 0; sb = 0;
  endtask
