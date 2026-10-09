// ***************
// Filename: usb_fs_sie_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the usb_fs_sie_tb testbench
//   (usb_fs_sie_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check          Counts an error and prints the message when the condition
//                    is false
//     axil_write     AXI4-Lite write of one register
//     axil_read      AXI4-Lite read of one register
//     get_rx
//     check_no_rx
//     get_tx
//     dut_send       DUT transmit
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

  task automatic get_rx();
    int t = 0;
    while (rx_len.size() <= rx_read && t < 400) begin
      #(BIT_NS);
      t++;
    end
    check(rx_len.size() > rx_read, "timeout waiting for a received packet");
    if (rx_len.size() > rx_read) begin
      rp_n = rx_len[rx_read];
      rp_err = rx_err[rx_read];
      for (int i = 0; i < rp_n; i++) rp[i] = rx_flat[rx_off + i];
      rx_off += rp_n;
      rx_read++;
    end
  endtask

  task automatic check_no_rx(input string what);
    #(BIT_NS * 30);
    check(rx_len.size() == rx_read, {"unexpected packet: ", what});
  endtask

  task automatic get_tx();
    int t = 0;
    while (usb.tp_pid.size() <= tp_read && t < 4000) begin
      #(BIT_NS);
      t++;
    end
    check(usb.tp_pid.size() > tp_read, "timeout waiting for a DUT packet");
    if (usb.tp_pid.size() > tp_read) begin
      tpb_pid = usb.tp_pid[tp_read];
      tpb_ok = usb.tp_ok[tp_read];
      tpb_n = usb.tp_n[tp_read];
      for (int i = 0; i < tpb_n; i++) tpb[i] = usb.tp_flat[tp_off + i];
      tp_off += tpb_n;
      tp_read++;
    end
  endtask

  // DUT transmit: byte0 = PID nibble, payload follows; whole packet is queued
  task automatic dut_send(input logic [3:0] pid, input int n);
    for (int i = 0; i <= n; i++) begin
      @(posedge aclk);
      #1;
      s_d = (i == 0) ? {4'h0, pid} : usb.pl[i-1];
      s_v = 1;
      s_l = (i == n);
      wait (s_r);
      @(posedge aclk);
      #1 s_v = 0;
      s_l = 0;
    end
  endtask
