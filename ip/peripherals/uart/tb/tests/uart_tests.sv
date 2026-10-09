// ***************
// Filename: uart_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the uart_tb testbench (uart_tb.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write   AXI4-Lite write of one register
//     axil_read    AXI4-Lite read of one register
//     stream_send  AXI-Stream helpers
//     serial_send  Serial driver (acts as external transmitter)
// Date: 2026-10-08
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin errors++; $display("ERROR @%0t: %s", $time, msg); end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    @(posedge aclk); #1;
    awaddr = a; awvalid = 1; wdata = d; wstrb = 4'hF; wvalid = 1; bready = 1;
    fork
      begin wait (awready); @(posedge aclk); #1 awvalid = 0; end
      begin wait (wready);  @(posedge aclk); #1 wvalid = 0;  end
    join
    wait (bvalid); @(posedge aclk); #1;
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    @(posedge aclk); #1; araddr = a; arvalid = 1; rready = 1;
    wait (arready); @(posedge aclk); #1 arvalid = 0;
    wait (rvalid); d = rdata; @(posedge aclk); #1;
  endtask

  // ---------- AXI-Stream helpers ----------
  task automatic stream_send(input [7:0] b);
    @(posedge aclk); #1; s_tdata = b; s_tvalid = 1; s_tlast = 0;
    wait (s_tready); @(posedge aclk); #1 s_tvalid = 0;
  endtask

  // ---------- Serial driver (acts as external transmitter) ----------
  task automatic serial_send(input [7:0] b, input int nbits, input bit pen,
                             input bit podd, input bit stop2,
                             input bit bad_par, input bit bad_stop);
    bit p; p = 0;
    rxd = 0; #(BIT_NS);                                  // start
    for (int i = 0; i < nbits; i++) begin
      rxd = b[i]; p ^= b[i]; #(BIT_NS);
    end
    if (pen) begin rxd = p ^ podd ^ bad_par; #(BIT_NS); end
    rxd = bad_stop ? 1'b0 : 1'b1; #(BIT_NS);             // stop
    rxd = 1'b1;
    if (bad_stop) #(BIT_NS);                             // let line recover
    if (stop2) #(BIT_NS);
  endtask
