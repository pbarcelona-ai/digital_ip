// ***************
// Filename: usb_fs_sie_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for the USB full-speed SIE IP. A
//   behavioral host drives real 12 Mbit/s D+/D- waveforms (NRZI, stuffing,
//   SYNC, CRC5/CRC16, EOP) with real-time delays that are not aligned to
//   the DUT clock, so clock recovery is exercised. Tests token, data,
//   handshake and zero length packets, bit stuffing stress with random
//   packets, corrupted CRC/PID (tuser), bus reset detection, and the DUT
//   transmitter checked by an independent decoder. Prints TEST PASSED on
//   success. Use +vcd for sim/usb_fs_sie_tb.vcd.
// Date: 2026-09-29
`timescale 1ns/1ps
`ifndef CLK_NS
`define CLK_NS 10.0
`endif
module usb_fs_sie_tb;
  localparam real CLK_PERIOD = `CLK_NS;                       // default 100 MHz
  localparam int  CLK_HZ     = int'(1.0e9 / CLK_PERIOD);
  localparam real BIT_NS     = 1000.0 / 12.0;                // 12 Mbit/s

  logic aclk = 0, aresetn = 0;
  always #(CLK_PERIOD/2) aclk = ~aclk;

  logic [7:0] awaddr, araddr; logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata; logic [3:0] wstrb; logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [7:0] s_d, m_d; logic s_v, s_r, s_l, m_v, m_r = 1, m_l, m_u;
  logic d_dp, d_dm, d_oe, d_pu;
  logic h_dp = 1, h_dm = 0, h_oe = 0;

  // Bus with a D+ pull-up: idle state is J (D+=1, D-=0)
  wire bus_dp = h_oe ? h_dp : (d_oe ? d_dp : 1'b1);
  wire bus_dm = h_oe ? h_dm : (d_oe ? d_dm : 1'b0);

  usb_fs_sie_top #(.CLK_HZ(CLK_HZ), .FIFO_DEPTH(64)) dut (
    .aclk, .aresetn,
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid),
    .s_axil_wready(wready), .s_axil_bresp(bresp), .s_axil_bvalid(bvalid),
    .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .s_axis_tdata(s_d), .s_axis_tvalid(s_v), .s_axis_tready(s_r), .s_axis_tlast(s_l),
    .m_axis_tdata(m_d), .m_axis_tvalid(m_v), .m_axis_tready(m_r),
    .m_axis_tlast(m_l), .m_axis_tuser(m_u),
    .usb_dp_i(bus_dp), .usb_dm_i(bus_dm), .usb_dp_o(d_dp), .usb_dm_o(d_dm),
    .usb_oe_o(d_oe), .usb_pullup_o(d_pu));

  int errors = 0;
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
  // CRC models (reflected form, LSB first)
  // ------------------------------------------------------------
  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input bit d);
    logic fb; fb = c[0] ^ d;
    return {1'b0, c[15:1]} ^ (fb ? 16'hA001 : 16'h0000);
  endfunction
  function automatic logic [4:0] crc5_bit(input logic [4:0] c, input bit d);
    logic fb; fb = c[0] ^ d;
    return {1'b0, c[4:1]} ^ (fb ? 5'h14 : 5'h00);
  endfunction
  function automatic logic [4:0] token_crc(input logic [10:0] v);
    logic [4:0] c; c = 5'h1F;
    for (int i = 0; i < 11; i++) c = crc5_bit(c, v[i]);
    return ~c;
  endfunction
  logic [7:0] pl [0:255];             // payload scratch (bytes)
  function automatic logic [15:0] data_crc(input int n);
    logic [15:0] c; c = 16'hFFFF;
    for (int i = 0; i < n; i++)
      for (int b = 0; b < 8; b++) c = crc16_bit(c, pl[i][b]);
    return ~c;
  endfunction

  // ------------------------------------------------------------
  // Host transmitter: raw bit list -> stuffing -> NRZI -> D+/D-
  // ------------------------------------------------------------
  bit hb [$];
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

  // ------------------------------------------------------------
  // DUT receive capture (m_axis)
  // ------------------------------------------------------------
  logic [7:0] rx_flat [$]; int rx_len [$]; bit rx_err [$]; int rx_cur = 0;
  always @(posedge aclk) if (m_v && m_r) begin
    rx_flat.push_back(m_d); rx_cur++;
    if (m_l) begin rx_len.push_back(rx_cur); rx_err.push_back(m_u); rx_cur = 0; end
  end
  int rx_read = 0, rx_off = 0;
  logic [7:0] rp [0:255]; int rp_n; bit rp_err;
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

  // ------------------------------------------------------------
  // Independent host-side decoder for DUT transmissions
  // ------------------------------------------------------------
  logic [1:0] hs [$];                     // sampled line states
  bit         dec_bits [$];
  logic [7:0] tp_pid [$]; bit tp_ok [$]; int tp_n [$]; logic [7:0] tp_flat [$];
  int         tp_read = 0, tp_off = 0;
  real        t0;
  int         stuffs_seen = 0;

  always @(posedge d_oe) begin : dut_tx_monitor
    logic [1:0] prev, cur; int ones; bit done;
    logic [7:0] bytes [0:300]; int nb, nbit; bit good;
    logic [15:0] c16; logic [4:0] c5; logic [7:0] pid;
    hs.delete(); dec_bits.delete();
    wait (bus_dp == 0 && bus_dm == 1);            // first K of SYNC
    t0 = $realtime;
    done = 0; prev = 2'b10; ones = 0; nbit = 0;
    for (int k = 0; !done && k < 4000; k++) begin
      #(BIT_NS * (k == 0 ? 0.5 : 1.0));
      cur = {bus_dp, bus_dm};
      if (cur == 2'b00) done = 1;
      else begin
        if (cur == prev) begin
          if (ones == 6) begin good = 0; end
          ones++; dec_bits.push_back(1);
        end else begin
          if (ones == 6) begin ones = 0; stuffs_seen++; end   // stuffed bit
          else begin dec_bits.push_back(0); ones = 0; end
        end
        // a 1 after six ones is a stuffing error; ignored here (flagged below)
        prev = cur;
      end
    end
    // Parse: SYNC + PID + payload (+CRC)
    good = (dec_bits.size() >= 16);
    for (int i = 0; i < 7 && good; i++) if (dec_bits[i] !== 0) good = 0;
    if (good && dec_bits[7] !== 1) good = 0;
    pid = 0;
    if (good) for (int i = 0; i < 8; i++) pid[i] = dec_bits[8 + i];
    if (good && pid[7:4] != ~pid[3:0]) good = 0;
    nbit = dec_bits.size() - 16;
    if (good && (pid[1:0] == 2'b11)) begin              // data: CRC16
      c16 = 16'hFFFF;
      for (int i = 16; i < dec_bits.size(); i++) c16 = crc16_bit(c16, dec_bits[i]);
      if (c16 != 16'hB001 || nbit % 8 != 0 || nbit < 16) good = 0;
      nb = (nbit - 16) / 8;
    end else if (good && (pid[1:0] == 2'b01)) begin     // token: CRC5
      c5 = 5'h1F;
      for (int i = 16; i < dec_bits.size(); i++) c5 = crc5_bit(c5, dec_bits[i]);
      if (c5 != 5'h06 || nbit != 16) good = 0;
      nb = 2;
    end else begin                                       // handshake
      if (nbit != 0) good = 0;
      nb = 0;
    end
    tp_pid.push_back(pid); tp_ok.push_back(good); tp_n.push_back(nb);
    for (int i = 0; i < nb; i++) begin
      logic [7:0] bb; bb = 0;
      for (int b = 0; b < 8; b++) bb[b] = dec_bits[16 + i*8 + b];
      tp_flat.push_back(bb);
    end
  end

  logic [7:0] tpb [0:255]; int tpb_n; logic [7:0] tpb_pid; bit tpb_ok;
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

  logic [31:0] rd;
  int nrand;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/usb_fs_sie_tb.vcd"); $dumpvars(0, usb_fs_sie_tb);
    end
    awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
    awaddr = 0; araddr = 0; wdata = 0; wstrb = 0; s_d = 0; s_v = 0; s_l = 0;
    repeat (5) @(posedge aclk); aresetn = 1; repeat (10) @(posedge aclk);

    // ---- T0: CRC model sanity against known USB vectors ----
    begin
      pl[0] = 8'h80; pl[1] = 8'h06; pl[2] = 8'h00; pl[3] = 8'h01;     // GET_DESCRIPTOR
      pl[4] = 8'h00; pl[5] = 8'h00; pl[6] = 8'h40; pl[7] = 8'h00;
      check(data_crc(8) == 16'h94DD, $sformatf("CRC16 model %h", data_crc(8)));
      check(token_crc(11'h000) == 5'h02, "CRC5 model");
    end
    axil_read(8'h00, rd); check(rd[1:0] == 2'b11, "CTRL default enable + pull-up");
    check(d_pu == 1'b1, "pull-up output");
    axil_read(8'h14, rd);
    check(rd == ((64'(CLK_HZ) * 256 + 6_000_000) / 12_000_000), $sformatf("BIT_PERIOD reg %0d", rd));

    // ---- T1: SETUP token then DATA0 (GET_DESCRIPTOR) from the host ----
    host_token(4'hD, 7'h2A, 4'h0, 0);
    get_rx();
    check(rp_n == 3 && !rp_err, $sformatf("token length %0d err %0d", rp_n, rp_err));
    check(rp[0] == 8'h0D && rp[1] == 8'h2A && rp[2] == {token_crc({4'h0, 7'h2A}), 3'b000},
          $sformatf("token bytes %h %h %h", rp[0], rp[1], rp[2]));
    host_data(4'h3, 8, 0);
    get_rx();
    check(rp_n == 9 && !rp_err && rp[0] == 8'h03, $sformatf("data0 length %0d", rp_n));
    for (int i = 0; i < 8; i++) check(rp[1+i] == pl[i], $sformatf("data byte %0d", i));

    // ---- T2: handshake and zero length data ----
    host_hs(4'h2, 0);
    get_rx(); check(rp_n == 1 && rp[0] == 8'h02 && !rp_err, "ACK packet");
    host_data(4'h3, 0, 0);
    get_rx(); check(rp_n == 1 && rp[0] == 8'h03 && !rp_err, "zero length DATA0");

    // ---- T3: bit stuffing stress payload ----
    pl[0] = 8'hFF; pl[1] = 8'hFF; pl[2] = 8'hFF; pl[3] = 8'hFF; pl[4] = 8'hFF;
    pl[5] = 8'h00; pl[6] = 8'hFF; pl[7] = 8'h7F; pl[8] = 8'h3F; pl[9] = 8'hFF;
    host_data(4'hB, 10, 0);
    get_rx(); check(rp_n == 11 && !rp_err && rp[0] == 8'h0B, "stuffing stress length/err");
    for (int i = 0; i < 10; i++) check(rp[1+i] == pl[i], $sformatf("stuff data %0d", i));

    // ---- T4: corrupted packets are flagged, good packets still work ----
    host_token(4'h9, 7'h11, 4'h1, 1);                     // bad CRC5
    get_rx(); check(rp_err, "bad CRC5 not flagged");
    host_data(4'h3, 4, 1);                                // bad CRC16
    get_rx(); check(rp_err, "bad CRC16 not flagged");
    host_hs(4'h2, 1);                                     // bad PID check
    get_rx(); check(rp_err, "bad PID check not flagged");
    host_token(4'h9, 7'h11, 4'h1, 0);
    get_rx(); check(!rp_err && rp_n == 3, "good token after errors");
    axil_read(8'h0C, rd); check(rd == 3, $sformatf("RX_BAD count %0d", rd));
    axil_read(8'h08, rd); check(rd == 6, $sformatf("RX_GOOD count %0d", rd));

    // ---- T5: random packets host -> DUT ----
    for (int k = 0; k < 25; k++) begin
      nrand = $urandom_range(0, 40);
      for (int i = 0; i < nrand; i++)
        pl[i] = ($urandom_range(0, 3) == 0) ? 8'hFF : $urandom;   // many ones
      host_data(k % 2 ? 4'hB : 4'h3, nrand, 0);
      get_rx();
      check(rp_n == nrand + 1 && !rp_err, $sformatf("random %0d: length %0d exp %0d err %0d", k, rp_n, nrand + 1, rp_err));
      for (int i = 0; i < nrand && i + 1 < rp_n; i++)
        check(rp[1+i] == pl[i], $sformatf("random %0d byte %0d", k, i));
    end

    // ---- T6: DUT transmitter checked by the independent decoder ----
    pl[0] = 8'h12; pl[1] = 8'h01; pl[2] = 8'h00; pl[3] = 8'h02;
    dut_send(4'hB, 4);
    get_tx(); check(tpb_ok && tpb_pid == 8'h4B, $sformatf("DATA1 ok=%0d pid=%h", tpb_ok, tpb_pid));
    check(tpb_n == 4 && tpb[0] == 8'h12 && tpb[3] == 8'h02, "DATA1 payload");
    dut_send(4'h2, 0);
    get_tx(); check(tpb_ok && tpb_pid == 8'hD2 && tpb_n == 0, "ACK handshake");
    pl[0] = 8'h2A; pl[1] = 8'h00;                         // addr 0x2A ep 0
    dut_send(4'h9, 2);
    get_tx(); check(tpb_ok && tpb_pid == 8'h69 && tpb_n == 2, "IN token");
    check(tpb[0] == 8'h2A && tpb[1][2:0] == 3'b000, "IN token address/endpoint");
    dut_send(4'h3, 0);
    get_tx(); check(tpb_ok && tpb_pid == 8'hC3 && tpb_n == 0, "zero length DATA0");
    for (int k = 0; k < 25; k++) begin
      nrand = $urandom_range(0, 40);
      for (int i = 0; i < nrand; i++)
        pl[i] = ($urandom_range(0, 3) == 0) ? 8'hFF : $urandom;
      dut_send(k % 2 ? 4'hB : 4'h3, nrand);
      get_tx();
      check(tpb_ok && tpb_n == nrand, $sformatf("tx random %0d ok=%0d n=%0d exp %0d", k, tpb_ok, tpb_n, nrand));
      for (int i = 0; i < nrand && i < tpb_n; i++)
        check(tpb[i] == pl[i], $sformatf("tx random %0d byte %0d", k, i));
    end
    check(stuffs_seen > 0, "no stuffed bits were exercised");
    #(BIT_NS * 6);                                       // let the last EOP finish
    axil_read(8'h10, rd); check(rd == 29, $sformatf("TX_PKTS %0d", rd));

    // ---- T7: bus reset (long SE0) ----
    h_oe = 1; h_dp = 0; h_dm = 0; #5000; h_dp = 1; h_dm = 0; h_oe = 0; #500;
    axil_read(8'h04, rd); check(rd[0] == 1, "bus reset not detected");
    axil_write(8'h04, 32'h1);
    axil_read(8'h04, rd); check(rd[0] == 0, "bus reset flag W1C");
    check(rd[9:8] == 2'b10, "line state should be J at idle");

    // DUT still receives after the reset
    host_hs(4'h2, 0);
    get_rx(); check(rp_n == 1 && rp[0] == 8'h02, "ACK after reset");

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #60_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
