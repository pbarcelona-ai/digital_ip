// ***************
// Filename: pcie_tl_ep_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the pcie_tl_ep_tb testbench
//   (pcie_tl_ep_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     axil_write  AXI4-Lite write of one register
//     axil_read   AXI4-Lite read of one register
//     wait_pkt
//     no_pkt
//     check_cpl   Completion field checks
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

  task automatic wait_pkt();
    int t = 0;
    while (pcie.tx_len.size() <= pkts_read && t < 2000) begin
      @(posedge aclk);
      t++;
    end
    check(pcie.tx_len.size() > pkts_read, "timeout waiting for a TLP from the endpoint");
    if (pcie.tx_len.size() > pkts_read) begin
      rp_n = pcie.tx_len[pkts_read];
      for (int i = 0; i < rp_n; i++) rp[i] = pcie.tx_flat[rd_off + i];
      rd_off += rp_n;
      pkts_read++;
    end
  endtask

  task automatic no_pkt(input string what);
    repeat (60) @(posedge aclk);
    check(pcie.tx_len.size() == pkts_read, {"unexpected TLP after ", what});
  endtask

  // Completion field checks
  task automatic check_cpl(input bit data, input int len, input logic [2:0] status,
                           input logic [7:0] tag, input logic [11:0] bytes,
                           input logic [6:0] low, input string what);
    check(rp[0][31:29] == (data ? 3'b010 : 3'b000) && rp[0][28:24] == 5'b01010,
          {what, ": completion fmt/type"});
    check(rp[0][9:0] == (data ? len : 0), {what, ": completion length"});
    check(rp[1][15:13] == status, {what, ": completion status"});
    check(rp[1][11:0] == bytes, $sformatf("%s: byte count %0d exp %0d", what, rp[1][11:0], bytes));
    check(rp[2][31:16] == HOST_ID && rp[2][15:8] == tag, {what, ": requester/tag"});
    check(rp[2][6:0] == low, {what, ": lower address"});
    check(rp_n == (data ? 3 + len : 3), $sformatf("%s: TLP DW count %0d", what, rp_n));
  endtask
