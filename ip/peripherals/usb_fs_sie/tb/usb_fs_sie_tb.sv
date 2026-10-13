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
  logic [7:0] reg_base = 8'h10;                   // the register map after the ID block
  logic [1:0] last_bresp;

  logic [31:0] rd;
  int nrand;
  `include "usb_fs_sie_tests.sv"
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

    test_id_block();
    test_crc_model();
    test_setup_data();
    test_handshake();
    test_bit_stuffing();
    test_corrupted();
    test_random_rx();
    test_tx();
    test_bus_reset();

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
