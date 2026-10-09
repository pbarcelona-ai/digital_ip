// ***************
// Filename: spi_flash_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the spi_flash_ctrl_tb testbench
//   (spi_flash_ctrl_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check         Counts an error and prints the message when the condition
//                   is false
//     cmd
//     wait_idle     Waits until the DUT is idle
//     flash_status
//     wait_wip
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end endtask

  task automatic cmd(input logic [7:0] op, input bit ae, input int dummy, input bit rdd, input bit wrd, input logic [23:0] a, input int len);
    bfm.write(8'h04, {8'd0, a}); bfm.write(8'h08, len);
    bfm.write(8'h00, {14'd0, wrd, rdd, dummy[3:0], 3'd0, ae, op});
  endtask

  task automatic wait_idle(); logic [31:0] s; do bfm.read(8'h10, s); while (s[0]); endtask

  task automatic flash_status(output logic [7:0] st);
    rxq.delete(); cmd(8'h05, 0, 0, 1, 0, 0, 1); wait_idle(); st = rxq.size() ? rxq[0] : 8'hxx;
  endtask

  task automatic wait_wip(); logic [7:0] s; int n; n = 0; do begin flash_status(s); n++; end while (s[0] && n < 200); check(n < 200, "WIP never cleared"); endtask
