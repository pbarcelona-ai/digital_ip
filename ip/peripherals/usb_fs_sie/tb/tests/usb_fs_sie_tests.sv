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
//     push_bits      Host transmitter
//     host_line
//     host_emit
//     host_sync_pid
//     host_token
//     host_data
//     host_hs
//     get_rx
//     check_no_rx
//     get_tx
//     dut_send       DUT transmit
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

  // ------------------------------------------------------------
  // Host transmitter: raw bit list -> stuffing -> NRZI -> D+/D-
  // ------------------------------------------------------------
  task automatic push_bits(input logic [31:0] v, input int n);
    for (int i = 0; i < n; i++) hb.push_back(v[i]);
  endtask

  task automatic host_line(input logic dp, input logic dm);
    h_dp = dp; h_dm = dm; #(BIT_NS);
  endtask

  task automatic host_emit();
    bit j; int ones;
    j = 1; ones = 0; h_oe = 1; h_dp = 1; h_dm = 0;
    for (int i = 0; i < hb.size(); i++) begin
      if (ones == 6) begin j = ~j; host_line(j, ~j); ones = 0; end     // stuff
      if (!hb[i]) j = ~j;
      ones = hb[i] ? ones + 1 : 0;
      host_line(j, ~j);
    end
    if (ones == 6) begin j = ~j; host_line(j, ~j); end
    host_line(0, 0); host_line(0, 0);                                  // EOP
    host_line(1, 0);
    h_oe = 0; hb.delete();
    #(BIT_NS * 6);                                                     // gap
  endtask

  task automatic host_sync_pid(input logic [3:0] pid, input bit bad_pid);
    push_bits(8'h80, 8);
    push_bits({(bad_pid ? pid : ~pid), pid}, 8);
  endtask

  task automatic host_token(input logic [3:0] pid, input logic [6:0] addr,
                            input logic [3:0] ep, input bit bad_crc);
    logic [10:0] v; v = {ep, addr};
    host_sync_pid(pid, 0); push_bits(v, 11);
    push_bits(bad_crc ? ~token_crc(v) : token_crc(v), 5);
    host_emit();
  endtask

  task automatic host_data(input logic [3:0] pid, input int n, input bit bad_crc);
    logic [15:0] c;
    host_sync_pid(pid, 0);
    for (int i = 0; i < n; i++) push_bits(pl[i], 8);
    c = data_crc(n); if (bad_crc) c = c ^ 16'h0100;
    push_bits(c, 16);
    host_emit();
  endtask

  task automatic host_hs(input logic [3:0] pid, input bit bad_pid);
    host_sync_pid(pid, bad_pid); host_emit();
  endtask

  task automatic get_rx();
    int t = 0;
    while (rx_len.size() <= rx_read && t < 400) begin #(BIT_NS); t++; end
    check(rx_len.size() > rx_read, "timeout waiting for a received packet");
    if (rx_len.size() > rx_read) begin
      rp_n = rx_len[rx_read]; rp_err = rx_err[rx_read];
      for (int i = 0; i < rp_n; i++) rp[i] = rx_flat[rx_off + i];
      rx_off += rp_n; rx_read++;
    end
  endtask

  task automatic check_no_rx(input string what);
    #(BIT_NS * 30);
    check(rx_len.size() == rx_read, {"unexpected packet: ", what});
  endtask

  task automatic get_tx();
    int t = 0;
    while (tp_pid.size() <= tp_read && t < 4000) begin #(BIT_NS); t++; end
    check(tp_pid.size() > tp_read, "timeout waiting for a DUT packet");
    if (tp_pid.size() > tp_read) begin
      tpb_pid = tp_pid[tp_read]; tpb_ok = tp_ok[tp_read]; tpb_n = tp_n[tp_read];
      for (int i = 0; i < tpb_n; i++) tpb[i] = tp_flat[tp_off + i];
      tp_off += tpb_n; tp_read++;
    end
  endtask

  // DUT transmit: byte0 = PID nibble, payload follows; whole packet is queued
  task automatic dut_send(input logic [3:0] pid, input int n);
    for (int i = 0; i <= n; i++) begin
      @(posedge aclk); #1;
      s_d = (i == 0) ? {4'h0, pid} : pl[i-1]; s_v = 1; s_l = (i == n);
      wait (s_r); @(posedge aclk); #1 s_v = 0; s_l = 0;
    end
  endtask
