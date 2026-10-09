// ***************
// Filename: reset_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the reset_ctrl_tb testbench
//   (reset_ctrl_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write   AXI-Lite master tasks
//     axil_read    AXI4-Lite read of one register
//     measure_low  Count consecutive cycles rst_o[0] stays asserted (low)
// Date: 2026-10-08
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR @%0t: %s", $time, msg); end
  endtask

  // ---------------- AXI-Lite master tasks ----------------
  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge aclk); #1;
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1; bready = 1;
    fork
      begin wait (awready); @(posedge aclk); #1 awvalid = 0; end
      begin wait (wready);  @(posedge aclk); #1 wvalid = 0;  end
    join
    wait (bvalid); @(posedge aclk); #1;
    check(bresp == 2'b00, "write response not OKAY");
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1; rready = 1;
    wait (arready); @(posedge aclk); #1 arvalid = 0;
    wait (rvalid); d = rdata; @(posedge aclk); #1;
  endtask

  // Count consecutive cycles rst_o[0] stays asserted (low)
  task automatic measure_low();
    low_cycles = 0;
    while (rst_o[0] == 1'b0) begin @(posedge aclk); low_cycles++; end
  endtask
