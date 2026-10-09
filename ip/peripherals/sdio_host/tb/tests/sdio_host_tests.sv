// ***************
// Filename: sdio_host_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the sdio_host_tb testbench (sdio_host_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     feed
//     wait_idle   Waits until the DUT is idle
//     cmd
//     set_bus
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic feed(input int n);
    for (int i = 0; i < n; i++) begin
      @(posedge aclk);
      #1 txv = 1;
      txd = src[i];
      while (!txr) begin
        @(posedge aclk);
        #1;
      end
    end
    @(posedge aclk);
    #1 txv = 0;
  endtask

  task automatic wait_idle();
    logic [31:0] s;
    do bfm.read(8'h18, s);
    while (s[0]);
  endtask

  task automatic cmd(input int idx, input int resp, input int dir, input bit nocrc, input logic [31:0] arg);
    bfm.write(8'h04, arg);
    bfm.write(8'h00, {21'd0, nocrc, dir[1:0], resp[1:0], idx[5:0]});
  endtask

  task automatic set_bus(input bit b4);
    card.bus4 = b4;
    bfm.write(8'h1C, {14'd0, 1'b1, b4, 16'd2});
  endtask
