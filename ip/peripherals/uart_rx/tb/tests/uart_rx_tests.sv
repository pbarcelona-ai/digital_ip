// ***************
// Filename: uart_rx_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the uart_rx_tb testbench (uart_rx_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check         Counts an error and prints the message when the condition
//                   is false
//     frame
//     expect_frame
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic frame(input logic [7:0] d, input int bits, input bit par, input bit odd, input bit bad_par, input bit bad_stop);
    uart.bit_ns = bt * 10.0;                    // bt clocks of 10 ns per bit
    uart.send_frame(d, bits, par, odd, 1'b0, bad_par, bad_stop);
  endtask

  task automatic expect_frame(input logic [7:0] d, input int bits, input bit fe, input bit pe_);
    repeat (20) @(posedge clk);
    check(rx_d.size() == exp_n + 1, $sformatf("frame not received (%0d checked, %0d received)", exp_n, rx_d.size()));
    if (rx_d.size() > exp_n) begin
      check(rx_d[exp_n] == (d & ((8'd1 << bits) - 1)), $sformatf("data %h exp %h", rx_d[exp_n], d & ((8'd1 << bits) - 1)));
      check(rx_f[exp_n] == fe, "frame error flag");
      check(rx_p[exp_n] == pe_, "parity error flag");
    end
    exp_n = rx_d.size();
  endtask
