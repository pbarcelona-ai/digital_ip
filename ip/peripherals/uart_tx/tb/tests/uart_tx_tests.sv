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
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic send_and_check(input logic [7:0] d, input int bits, input bit par, input bit odd, input bit two);
    int n0;
    nb = bits;
    pe = par;
    po = odd;
    s2 = two;
    uart.nbits = bits;                          // receiver line format = DUT setting
    uart.parity_en = par;
    uart.parity_odd = odd;
    uart.stop2 = two;
    n0 = uart.rx_count;
    @(posedge clk);
    #1 td = d;
    tv = 1;
    @(posedge clk);
    while (!tr) @(posedge clk);
    #1 tv = 0;
    wait (uart.rx_count == n0 + 1);
    check(uart.rx_data == (d & ((8'd1 << bits) - 1)),
          $sformatf("data %0d bits: got %h exp %h", bits, uart.rx_data, d));
    check(!uart.rx_perr, "parity bit");
    check(!uart.rx_ferr, "stop bit");
    while (busy) @(posedge clk);
  endtask
