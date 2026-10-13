// ***************
// Filename: usb_fs_sie_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the usb_fs_sie_tb testbench
//   (usb_fs_sie_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check          Counts an error and prints the message when the condition
//                    is false
//     axil_write  (offset from reg_base = 0x10, the map after the ID block;
//                  axil_write_abs / axil_read_abs: absolute, BRESP in last_bresp)
//     axil_write     AXI4-Lite write of one register
//     axil_read      AXI4-Lite read of one register
//     get_rx
//     check_no_rx
//     get_tx
//     dut_send       DUT transmit
//     test_id_block      ID "USBF", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                        0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_crc_model     CRC model against known USB vectors; CTRL and
//                        BIT_PERIOD reset values
//     test_setup_data    SETUP token then DATA0 (GET_DESCRIPTOR) from the host
//     test_handshake     Handshake and zero-length data
//     test_bit_stuffing  Bit stuffing stress payload
//     test_corrupted     Corrupted packets flagged, good packets still work
//     test_random_rx     Random packets host -> DUT
//     test_tx            DUT transmitter checked by the independent decoder
//     test_bus_reset     Bus reset (long SE0) sets BUS_RESET, W1C clears it
// Date: 2026-10-12
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    axil_write_abs(a + reg_base, d);
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    axil_read_abs(a + reg_base, d);
  endtask

  task automatic axil_write_abs(input [7:0] a, input [31:0] d);
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
    last_bresp = bresp;
    @(posedge aclk);
    #1;
  endtask

  task automatic axil_read_abs(input [7:0] a, output [31:0] d);
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

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "USBF", $sformatf("ID %h (\"%s\"), expected \"USBF\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      axil_write_abs(8'(a), 32'hA5A5_5A5A);
      check(last_bresp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, last_bresp));
    end

    axil_read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_crc_model();
    // ---- Test 0: CRC model sanity against known USB vectors ----
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
  endtask

  task automatic test_setup_data();
    // ---- Test 1: SETUP token then DATA0 (GET_DESCRIPTOR) from the host ----
    usb.host_token(4'hD, 7'h2A, 4'h0, 0);
    get_rx();
    check(rp_n == 3 && !rp_err, $sformatf("token length %0d err %0d", rp_n, rp_err));
    check(rp[0] == 8'h0D && rp[1] == 8'h2A && rp[2] == {usb.token_crc({4'h0, 7'h2A}), 3'b000},
          $sformatf("token bytes %h %h %h", rp[0], rp[1], rp[2]));
    usb.host_data(4'h3, 8, 0);
    get_rx();
    check(rp_n == 9 && !rp_err && rp[0] == 8'h03, $sformatf("data0 length %0d", rp_n));
    for (int i = 0; i < 8; i++) check(rp[1+i] == usb.pl[i], $sformatf("data byte %0d", i));
  endtask

  task automatic test_handshake();
    // ---- Test 2: handshake and zero length data ----
    usb.host_hs(4'h2, 0);
    get_rx();
    check(rp_n == 1 && rp[0] == 8'h02 && !rp_err, "ACK packet");
    usb.host_data(4'h3, 0, 0);
    get_rx();
    check(rp_n == 1 && rp[0] == 8'h03 && !rp_err, "zero length DATA0");
  endtask

  task automatic test_bit_stuffing();
    // ---- Test 3: bit stuffing stress payload ----
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
  endtask

  task automatic test_corrupted();
    // ---- Test 4: corrupted packets are flagged, good packets still work ----
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
  endtask

  task automatic test_random_rx();
    // ---- Test 5: random packets host -> DUT ----
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
  endtask

  task automatic test_tx();
    // ---- Test 6: DUT transmitter checked by the independent decoder ----
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
  endtask

  task automatic test_bus_reset();
    // ---- Test 7: bus reset (long SE0) ----
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
  endtask
