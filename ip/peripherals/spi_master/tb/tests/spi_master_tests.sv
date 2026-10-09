// ***************
// Filename: spi_master_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the spi_master_tb testbench
//   (spi_master_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     send
//     xfer   Configure and run one single-word transfer, check both directions
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic send(input [31:0] w, input bit last);
    @(posedge aclk); #1; s_axis_tdata = w; s_axis_tvalid = 1; s_axis_tlast = last;
    wait (s_axis_tready); @(posedge aclk); #1 s_axis_tvalid = 0;
  endtask

  // Configure and run one single-word transfer, check both directions
  task automatic xfer(input logic p, input logic h, input logic l,
                      input int n, input [31:0] mosi_w, input [31:0] miso_w);
    logic [31:0] mask;
    mask = (n == 32) ? 32'hFFFF_FFFF : ((32'd1 << n) - 1);
    cpol = p; cpha = h; lsb = l; nbits = n; slv_tx = miso_w & mask;
    bfm.write(8'h00, {16'd0, 8'd1, 4'd0, l, h, p, 1'b1});   // cs_select=1
    bfm.write(8'h08, n);
    rxq.delete(); rxlast.delete();
    send(mosi_w & mask, 1);
    while (rxq.size() != 1) @(posedge aclk); repeat (10) @(posedge aclk);
    check(slv_rx == (mosi_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MOSI got %08h exp %08h",
          p, h, l, n, slv_rx, mosi_w & mask));
    check(rxq[0] == (miso_w & mask), $sformatf("mode %0d%0d lsb=%0d n=%0d MISO got %08h exp %08h",
          p, h, l, n, rxq[0], miso_w & mask));
    check(cs_n == '1, "CS not released after tlast");
  endtask
