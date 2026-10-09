// ***************
// Filename: eth_mac_if_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for eth_mac_if. Random frames (1 to
//   200 bytes) are sent through the transmitter and looped back to the
//   receiver; the GMII wire is checked for the 7 x 0x55 plus 0xD5
//   preamble, contiguous tx_en, padding to 60 bytes, the FCS against an
//   independent CRC-32 model and the 12 byte gap; the receiver output must
//   equal the padded frame with tlast on the last byte and tuser low.
//   Additional cases - a corrupted bit on the wire (tuser high,
//   crc_err_o), a frame shorter than 64 bytes injected directly (short_o),
//   gmii_rx_er, a source gap that must abort with underrun_o, and receive
//   overflow when the master stalls. Prints TEST PASSED on success.
//   The test tasks are in tests/eth_mac_if_tests.sv (`included).
// Date: 2026-09-29
`timescale 1ns/1ps
module eth_mac_if_tb;
  logic clk = 0, rst_n = 0; // 125 MHz
  always #4 clk = ~clk;
  logic [7:0] sd = 0, md;
  logic sl = 0, sv = 0, sr, ml, mu, mv, mr = 1;
  logic [7:0] txd, rxd;
  logic tx_en, tx_er, rx_dv, rx_er;
  logic under, ovf, crc_err, shrt, rxerr;
  eth_mac_if dut (
    .clk,
    .aresetn(rst_n),
    .s_axis_tdata(sd),
    .s_axis_tlast(sl),
    .s_axis_tvalid(sv),
    .s_axis_tready(sr),
    .m_axis_tdata(md),
    .m_axis_tlast(ml),
    .m_axis_tuser(mu),
    .m_axis_tvalid(mv),
    .m_axis_tready(mr),
    .gmii_txd(txd),
    .gmii_tx_en(tx_en),
    .gmii_tx_er(tx_er),
    .gmii_rxd(rxd),
    .gmii_rx_dv(rx_dv),
    .gmii_rx_er(rx_er),
    .underrun_o(under),
    .overflow_o(ovf),
    .crc_err_o(crc_err),
    .short_o(shrt),
    .rx_err_o(rxerr)
  );
  // GMII PHY: transmit monitor, receive loopback / frame injection
  eth_bfm phy (
    .clk,
    .txd,
    .tx_en,
    .tx_er,
    .rxd,
    .rx_dv,
    .rx_er
  );
  int errors = 0;
  byte rx_data[$];
  int rx_len[$];
  bit rx_users[$];
  int rcur = 0, rx_frames = 0, crc_errs = 0, shorts = 0, rxerrs = 0, ovfs = 0, unders = 0;
  always @(posedge clk) begin
    if (mv && mr) begin
      rx_data.push_back(md);
      rcur++;
      if (ml) begin
        rx_len.push_back(rcur);
        rcur = 0;
        rx_users.push_back(mu);
        rx_frames++;
      end
      else if (mu) begin
        errors++;
        $display("ERROR tuser without tlast");
      end
    end
    if (crc_err) crc_errs++;
    if (shrt) shorts++;
    if (rxerr) rxerrs++;
    if (ovf) ovfs++;
    if (under) unders++;
  end
  // used by task send_frame_ok (tests/eth_mac_if_tests.sv)
  byte sent_data[$];
  int sent_len[$];
  // test tasks: tests/eth_mac_if_tests.sv
  `include "eth_mac_if_tests.sv"
  int so = 0, wo = 0, ro = 0;                        // offsets into the flat queues
  initial begin
    if ($test$plusargs("vcd")) begin
      $dumpfile("eth_mac_if_tb.vcd");
      $dumpvars(0, eth_mac_if_tb);
    end
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);
    for (int n = 0; n < 40; n++) begin
      int len;
      len = ($urandom_range(0, 3) == 0) ? $urandom_range(1, 59) : $urandom_range(60, 200);
      send_frame_ok(len);
      repeat (20) @(posedge clk);
    end
    repeat (100) @(posedge clk);
    // ------------ verify all frames ------------
    check(phy.wire_len.size() == sent_len.size(), $sformatf("frames on wire %0d, sent %0d", phy.wire_len.size(), sent_len.size()));
    check(rx_len.size() == sent_len.size(), $sformatf("frames received %0d, sent %0d", rx_len.size(), sent_len.size()));
    for (int fnum = 0; fnum < sent_len.size() && fnum < phy.wire_len.size() && fnum < rx_len.size(); fnum++) begin
      int n, pn;
      logic [31:0] c;
      n = sent_len[fnum];
      pn = (n < 60) ? 60 : n;
      phy.cq.delete();
      for (int i = 0; i < pn; i++) phy.cq.push_back(i < n ? sent_data[so + i] : 8'h00);
      c = phy.crc_model(pn);
      check(phy.wire_len[fnum] == pn + 12, $sformatf("frame %0d wire length %0d expected %0d", fnum, phy.wire_len[fnum], pn + 12));
      if (phy.wire_len[fnum] == pn + 12) begin
        for (int i = 0; i < 7; i++) check(phy.wire_data[wo + i] == 8'h55, "preamble");
        check(phy.wire_data[wo + 7] == 8'hD5, "SFD");
        for (int i = 0; i < pn; i++) if (phy.wire_data[wo + 8 + i] != phy.cq[i]) begin
          check(0, $sformatf("frame %0d wire byte %0d", fnum, i));
          i = pn;
        end
        for (int i = 0; i < 4; i++) check(phy.wire_data[wo + 8 + pn + i] == c[i*8 +: 8], $sformatf("frame %0d FCS byte %0d", fnum, i));
      end
      check(rx_len[fnum] == pn, $sformatf("frame %0d rx length %0d expected %0d", fnum, rx_len[fnum], pn));
      if (rx_len[fnum] == pn) for (int i = 0; i < pn; i++) if (rx_data[ro + i] != phy.cq[i]) begin
        check(0, $sformatf("frame %0d rx byte %0d", fnum, i));
        i = pn;
      end
      check(rx_users[fnum] == (pn + 4 < 64), $sformatf("frame %0d tuser %b", fnum, rx_users[fnum]));
      so += n;
      wo += phy.wire_len[fnum];
      ro += rx_len[fnum];
    end
    check(phy.min_gap >= 12, $sformatf("inter-frame gap %0d", phy.min_gap));
    check(ovfs == 0 && unders == 0 && crc_errs == 0 && rxerrs == 0, "unexpected error pulses");
    // ------------ corrupted bit on the wire ------------
    begin
      int f0;
      f0 = rx_frames;
      phy.flip = 1;
      send_frame_ok(80);
      repeat (100) @(posedge clk);
      phy.flip = 0;
      check(rx_frames == f0 + 1 && rx_users[rx_users.size()-1] == 1'b1 && crc_errs == 1, $sformatf("corrupted frame: frames %0d tuser %b crc_errs %0d", rx_frames - f0, rx_users[rx_users.size()-1], crc_errs));
    end
    // ------------ direct injection: short frame with valid FCS, and gmii_rx_er ------------
    phy.loop = 0;
    repeat (3) @(posedge clk);
    begin
      int f0;
      f0 = rx_frames;
      inject_frame(30, -1);
      check(shorts == 1 && crc_errs == 1 && rx_frames == f0 + 1 && rx_users[rx_users.size()-1] == 1, "short frame not flagged");
      inject_frame(70, 30);
      check(rxerrs == 1 && rx_users[rx_users.size()-1] == 1, "rx_er not flagged");
      inject_frame(70, -1); // good frame through the injection path
      check(rx_users[rx_users.size()-1] == 0 && crc_errs == 1, "good injected frame rejected");
    end
    phy.loop = 1;
    // ------------ source gap aborts the frame ------------
    begin
      int u0;
      u0 = unders;
      @(posedge clk);
      #1 sv = 1;
      sd = 8'h11;
      sl = 0;
      while (!sr) @(posedge clk);
      @(posedge clk);
      #1 sv = 0;
      repeat (30) @(posedge clk);
      check(unders == u0 + 1, "underrun not flagged");
      repeat (30) @(posedge clk);
    end
    // ------------ receive overflow ------------
    begin
      int o0;
      o0 = ovfs;
      mr = 0;
      send_frame_ok(70);
      repeat (200) @(posedge clk);
      mr = 1;
      check(ovfs > o0, "overflow not flagged");
    end
    if (errors == 0) $display("TEST PASSED");
    else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin
    #20_000_000;
    $display("TEST FAILED (timeout)");
    $finish;
  end
endmodule
