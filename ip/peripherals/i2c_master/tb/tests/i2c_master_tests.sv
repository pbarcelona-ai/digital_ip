// ***************
// Filename: i2c_master_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the i2c_master_tb testbench
//   (i2c_master_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write   AXI4-Lite write of one register
//     axil_read    AXI4-Lite read of one register
//     stream_send  Sends one AXI4-Stream beat
//     i2c_xfer     Run a transaction and wait for the done flag
// Date: 2026-10-08
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge aclk);
    #1;
    awaddr = a;
    awvalid = 1;
    wdata = d;
    wstrb = 4'hF;
    wvalid = 1;
    bready = 1;
    fork
      begin
        wait (awready);
        @(posedge aclk);
        #1 awvalid = 0;
      end
      begin
        wait (wready);
        @(posedge aclk);
        #1 wvalid = 0;
      end
    join
    wait (bvalid);
    @(posedge aclk);
    #1;
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    araddr = a;
    arvalid = 1;
    rready = 1;
    wait (arready);
    @(posedge aclk);
    #1 arvalid = 0;
    wait (rvalid);
    d = rdata;
    @(posedge aclk);
    #1;
  endtask

  task automatic stream_send(input [7:0] b);
    @(posedge aclk);
    #1;
    s_tdata = b;
    s_tvalid = 1;
    s_tlast = 0;
    wait (s_tready);
    @(posedge aclk);
    #1 s_tvalid = 0;
  endtask

  // Run a transaction and wait for the done flag
  task automatic i2c_xfer(input [6:0] a, input bit read, input int len,
                          input bit nostop);
    axil_write(8'h04, {25'd0, a});
    axil_write(8'h08, len);
    axil_write(8'h10, 32'hE);                           // clear flags
    axil_write(8'h00, {28'd0, nostop, read, 1'b1, 1'b1});
    do axil_read(8'h10, rd); // wait for done
    while (rd[1] == 1'b0);
  endtask
