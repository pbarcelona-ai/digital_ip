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
//   The test tasks are in tests/usb_fs_sie_tests.sv (`included).
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

  logic [7:0] awaddr, araddr;
  logic awvalid, awready, wvalid, wready;
  logic [31:0] wdata, rdata;
  logic [3:0] wstrb;
  logic [1:0] bresp, rresp;
  logic bvalid, bready, arvalid, arready, rvalid, rready;
  logic [7:0] s_d, m_d;
  logic s_v, s_r, s_l, m_v, m_r = 1, m_l, m_u;
  logic d_dp, d_dm, d_oe, d_pu;

  wire bus_dp, bus_dm;                                       // resolved bus (usb_bfm)

  usb_fs_sie_top #(
    .CLK_HZ(CLK_HZ),
    .FIFO_DEPTH(64)
  ) dut (
    .aclk,
    .aresetn,
    .s_axil_awaddr(awaddr),
    .s_axil_awvalid(awvalid),
    .s_axil_awready(awready),
    .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb),
    .s_axil_wvalid(wvalid),
    .s_axil_wready(wready),
    .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid),
    .s_axil_bready(bready),
    .s_axil_araddr(araddr),
    .s_axil_arvalid(arvalid),
    .s_axil_arready(arready),
    .s_axil_rdata(rdata),
    .s_axil_rresp(rresp),
    .s_axil_rvalid(rvalid),
    .s_axil_rready(rready),
    .s_axis_tdata(s_d),
    .s_axis_tvalid(s_v),
    .s_axis_tready(s_r),
    .s_axis_tlast(s_l),
    .m_axis_tdata(m_d),
    .m_axis_tvalid(m_v),
    .m_axis_tready(m_r),
    .m_axis_tlast(m_l),
    .m_axis_tuser(m_u),
    .usb_dp_i(bus_dp),
    .usb_dm_i(bus_dm),
    .usb_dp_o(d_dp),
    .usb_dm_o(d_dm),
    .usb_oe_o(d_oe),
    .usb_pullup_o(d_pu)
  );

  int errors = 0;

  // ------------------------------------------------------------
  // USB host: bus with the D+ pull-up, transmitter, independent decoder
  // ------------------------------------------------------------
  usb_bfm #(.BIT_NS(BIT_NS)) usb (
    .d_dp,
    .d_dm,
    .d_oe,
    .bus_dp,
    .bus_dm
  );

  // ------------------------------------------------------------
  // DUT receive capture (m_axis)
  // ------------------------------------------------------------
  logic [7:0] rx_flat [$];
  int rx_len [$];
  bit rx_err [$];
  int rx_cur = 0;
  always @(posedge aclk) if (m_v && m_r) begin
    rx_flat.push_back(m_d);
    rx_cur++;
    if (m_l) begin
      rx_len.push_back(rx_cur);
      rx_err.push_back(m_u);
      rx_cur = 0;
    end
  end
  int rx_read = 0, rx_off = 0;
  logic [7:0] rp [0:255];
  int rp_n;
  bit rp_err;

  int tp_read = 0, tp_off = 0;                               // read position in the usb_bfm decoder queues
  logic [7:0] tpb [0:255];
  int tpb_n;
  logic [7:0] tpb_pid;
  bit tpb_ok;

  // test tasks: tests/usb_fs_sie_tests.sv
  `include "usb_fs_sie_tests.sv"

  logic [31:0] rd;
  int nrand;
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("sim/usb_fs_sie_tb.vcd");
      $dumpvars(0, usb_fs_sie_tb);
    end
    awvalid = 0;
    wvalid = 0;
    bready = 0;
    arvalid = 0;
    rready = 0;
    awaddr = 0;
    araddr = 0;
    wdata = 0;
    wstrb = 0;
    s_d = 0;
    s_v = 0;
    s_l = 0;
    repeat (5) @(posedge aclk);
    aresetn = 1;
    repeat (10) @(posedge aclk);

    // ---- T0: CRC model sanity against known USB vectors ----
    begin
      usb.pl[0] = 8'h80; // GET_DESCRIPTOR
      usb.pl[1] = 8'h06;
      usb.pl[2] = 8'h00;
      usb.pl[3] = 8'h01;
      usb.pl[4] = 8'h00;
      usb.pl[5] = 8'h00;
      usb.pl[6] = 8'h40;
      usb.pl[7] = 8'h00;
      check(usb.data_crc(8) == 16'h94DD, $sformatf("CRC16 model %h", usb.data_crc(8)));
      check(usb.token_crc(11'h000) == 5'h02, "CRC5 model");
    end
    axil_read(8'h00, rd);
    check(rd[1:0] == 2'b11, "CTRL default enable + pull-up");
    check(d_pu == 1'b1, "pull-up output");
    axil_read(8'h14, rd);
    check(rd == ((64'(CLK_HZ) * 256 + 6_000_000) / 12_000_000), $sformatf("BIT_PERIOD reg %0d", rd));

    // ---- T1: SETUP token then DATA0 (GET_DESCRIPTOR) from the host ----
    usb.host_token(4'hD, 7'h2A, 4'h0, 0);
    get_rx();
    check(rp_n == 3 && !rp_err, $sformatf("token length %0d err %0d", rp_n, rp_err));
    check(rp[0] == 8'h0D && rp[1] == 8'h2A && rp[2] == {usb.token_crc({4'h0, 7'h2A}), 3'b000},
          $sformatf("token bytes %h %h %h", rp[0], rp[1], rp[2]));
    usb.host_data(4'h3, 8, 0);
    get_rx();
    check(rp_n == 9 && !rp_err && rp[0] == 8'h03, $sformatf("data0 length %0d", rp_n));
    for (int i = 0; i < 8; i++) check(rp[1+i] == usb.pl[i], $sformatf("data byte %0d", i));

    // ---- T2: handshake and zero length data ----
    usb.host_hs(4'h2, 0);
    get_rx();
    check(rp_n == 1 && rp[0] == 8'h02 && !rp_err, "ACK packet");
    usb.host_data(4'h3, 0, 0);
    get_rx();
    check(rp_n == 1 && rp[0] == 8'h03 && !rp_err, "zero length DATA0");

    // ---- T3: bit stuffing stress payload ----
    usb.pl[0] = 8'hFF;
    usb.pl[1] = 8'hFF;
    usb.pl[2] = 8'hFF;
    usb.pl[3] = 8'hFF;
    usb.pl[4] = 8'hFF;
    usb.pl[5] = 8'h00;
    usb.pl[6] = 8'hFF;
    usb.pl[7] = 8'h7F;
    usb.pl[8] = 8'h3F;
    usb.pl[9] = 8'hFF;
    usb.host_data(4'hB, 10, 0);
    get_rx();
    check(rp_n == 11 && !rp_err && rp[0] == 8'h0B, "stuffing stress length/err");
    for (int i = 0; i < 10; i++) check(rp[1+i] == usb.pl[i], $sformatf("stuff data %0d", i));

    // ---- T4: corrupted packets are flagged, good packets still work ----
    usb.host_token(4'h9, 7'h11, 4'h1, 1);                     // bad CRC5
    get_rx();
    check(rp_err, "bad CRC5 not flagged");
    usb.host_data(4'h3, 4, 1);                                // bad CRC16
    get_rx();
    check(rp_err, "bad CRC16 not flagged");
    usb.host_hs(4'h2, 1);                                     // bad PID check
    get_rx();
    check(rp_err, "bad PID check not flagged");
    usb.host_token(4'h9, 7'h11, 4'h1, 0);
    get_rx();
    check(!rp_err && rp_n == 3, "good token after errors");
    axil_read(8'h0C, rd);
    check(rd == 3, $sformatf("RX_BAD count %0d", rd));
    axil_read(8'h08, rd);
    check(rd == 6, $sformatf("RX_GOOD count %0d", rd));

    // ---- T5: random packets host -> DUT ----
    for (int k = 0; k < 25; k++) begin
      nrand = $urandom_range(0, 40);
      for (int i = 0; i < nrand; i++)
        usb.pl[i] = ($urandom_range(0, 3) == 0) ? 8'hFF : $urandom;   // many ones
      usb.host_data(k % 2 ? 4'hB : 4'h3, nrand, 0);
      get_rx();
      check(rp_n == nrand + 1 && !rp_err, $sformatf("random %0d: length %0d exp %0d err %0d", k, rp_n, nrand + 1, rp_err));
      for (int i = 0; i < nrand && i + 1 < rp_n; i++)
        check(rp[1+i] == usb.pl[i], $sformatf("random %0d byte %0d", k, i));
    end

    // ---- T6: DUT transmitter checked by the independent decoder ----
    usb.pl[0] = 8'h12;
    usb.pl[1] = 8'h01;
    usb.pl[2] = 8'h00;
    usb.pl[3] = 8'h02;
    dut_send(4'hB, 4);
    get_tx();
    check(tpb_ok && tpb_pid == 8'h4B, $sformatf("DATA1 ok=%0d pid=%h", tpb_ok, tpb_pid));
    check(tpb_n == 4 && tpb[0] == 8'h12 && tpb[3] == 8'h02, "DATA1 payload");
    dut_send(4'h2, 0);
    get_tx();
    check(tpb_ok && tpb_pid == 8'hD2 && tpb_n == 0, "ACK handshake");
    usb.pl[0] = 8'h2A; // addr 0x2A ep 0
    usb.pl[1] = 8'h00;
    dut_send(4'h9, 2);
    get_tx();
    check(tpb_ok && tpb_pid == 8'h69 && tpb_n == 2, "IN token");
    check(tpb[0] == 8'h2A && tpb[1][2:0] == 3'b000, "IN token address/endpoint");
    dut_send(4'h3, 0);
    get_tx();
    check(tpb_ok && tpb_pid == 8'hC3 && tpb_n == 0, "zero length DATA0");
    for (int k = 0; k < 25; k++) begin
      nrand = $urandom_range(0, 40);
      for (int i = 0; i < nrand; i++)
        usb.pl[i] = ($urandom_range(0, 3) == 0) ? 8'hFF : $urandom;
      dut_send(k % 2 ? 4'hB : 4'h3, nrand);
      get_tx();
      check(tpb_ok && tpb_n == nrand, $sformatf("tx random %0d ok=%0d n=%0d exp %0d", k, tpb_ok, tpb_n, nrand));
      for (int i = 0; i < nrand && i < tpb_n; i++)
        check(tpb[i] == usb.pl[i], $sformatf("tx random %0d byte %0d", k, i));
    end
    check(usb.stuffs_seen > 0, "no stuffed bits were exercised");
    #(BIT_NS * 6);                                       // let the last EOP finish
    axil_read(8'h10, rd);
    check(rd == 29, $sformatf("TX_PKTS %0d", rd));

    // ---- T7: bus reset (long SE0) ----
    usb.bus_reset(5000);
    #500;
    axil_read(8'h04, rd);
    check(rd[0] == 1, "bus reset not detected");
    axil_write(8'h04, 32'h1);
    axil_read(8'h04, rd);
    check(rd[0] == 0, "bus reset flag W1C");
    check(rd[9:8] == 2'b10, "line state should be J at idle");

    // DUT still receives after the reset
    usb.host_hs(4'h2, 0);
    get_rx();
    check(rp_n == 1 && rp[0] == 8'h02, "ACK after reset");

    if (errors == 0) $display("TEST PASSED");
    else             $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #60_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
