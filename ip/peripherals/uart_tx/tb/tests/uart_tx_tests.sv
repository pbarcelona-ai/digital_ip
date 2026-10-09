// ***************
// Filename: uart_tx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the uart_tx_tb testbench (uart_tx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check           Counts an error and prints the message when the
//                     condition is false
//     send_and_check
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end endtask

  task automatic send_and_check(input logic [7:0] d, input int bits, input bit par, input bit odd, input bit two);
    logic [7:0] got; bit p, pchk; int exp_par;
    nb = bits; pe = par; po = odd; s2 = two;
    fork
      begin @(posedge clk); #1 td = d; tv = 1; @(posedge clk); while (!tr) @(posedge clk); #1 tv = 0; end
      begin @(negedge txd); end
    join
    repeat (50) @(posedge clk); #1; check(txd == 0, "start bit");
    got = 0;
    for (int i = 0; i < bits; i++) begin repeat (100) @(posedge clk); #1 got[i] = txd; end
    exp_par = 0; for (int i = 0; i < bits; i++) exp_par ^= d[i];
    check(got == (d & ((8'd1 << bits) - 1)), $sformatf("data %0d bits: got %h exp %h", bits, got, d));
    if (par) begin repeat (100) @(posedge clk); #1; check(txd == (odd ? ~exp_par[0] : exp_par[0]), "parity bit"); end
    repeat (100) @(posedge clk); #1; check(txd == 1, "stop bit 1");
    if (two) begin repeat (100) @(posedge clk); #1; check(txd == 1, "stop bit 2"); end
    while (busy) @(posedge clk);
  endtask
