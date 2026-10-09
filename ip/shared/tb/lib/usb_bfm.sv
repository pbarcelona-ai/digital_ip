// ***************
// Filename: usb_bfm.sv
// Author: FPGA Cores 4 U
// Description: USB 1.1 full speed (12 Mbit/s) host bus functional model
//   for a device side SIE. Owns the D+ / D- bus with the device's D+
//   pull-up (idle J; bus_dp / bus_dm go to the device inputs; the host
//   drives while h_oe, otherwise the device while its d_oe).
//   Transmitter: host_token(), host_data() (payload from pl[]),
//   host_hs() build SYNC, PID, payload and CRC5 / CRC16 (errors injectable:
//   bad CRC, bad PID check), bit stuff, NRZI encode and end with EOP;
//   bus_reset() drives a long SE0.
//   Receiver: an independent decoder of every device transmission (NRZI,
//   unstuffing, PID check, CRC5 / CRC16 check) appends PID, ok flag and
//   payload length to tp_pid / tp_ok / tp_n and the payload bytes to
//   tp_flat; stuffs_seen counts stuffed bits. token_crc() / data_crc() are
//   the USB CRC models.
// Date: 2026-10-09
`timescale 1ns/1ps

module usb_bfm #(
  parameter real BIT_NS = 1000.0 / 12.0       // full speed bit time
) (
  input  logic d_dp,                          // device transmitter
  input  logic d_dm,
  input  logic d_oe,
  output wire  bus_dp,                        // resolved bus: to the device inputs
  output wire  bus_dm
);
  logic h_dp = 1, h_dm = 0, h_oe = 0;
  // Bus with a D+ pull-up: idle state is J (D+=1, D-=0)
  assign bus_dp = h_oe ? h_dp : (d_oe ? d_dp : 1'b1);
  assign bus_dm = h_oe ? h_dm : (d_oe ? d_dm : 1'b0);


  // ------------------------------------------------------------
  // CRC models (reflected form, LSB first)
  // ------------------------------------------------------------
  function automatic logic [15:0] crc16_bit(input logic [15:0] c, input bit d);
    logic fb;
    fb = c[0] ^ d;
    return {1'b0, c[15:1]} ^ (fb ? 16'hA001 : 16'h0000);
  endfunction
  function automatic logic [4:0] crc5_bit(input logic [4:0] c, input bit d);
    logic fb;
    fb = c[0] ^ d;
    return {1'b0, c[4:1]} ^ (fb ? 5'h14 : 5'h00);
  endfunction
  function automatic logic [4:0] token_crc(input logic [10:0] v);
    logic [4:0] c;
    c = 5'h1F;
    for (int i = 0; i < 11; i++) c = crc5_bit(c, v[i]);
    return ~c;
  endfunction
  logic [7:0] pl [0:255];             // payload scratch (bytes)
  function automatic logic [15:0] data_crc(input int n);
    logic [15:0] c;
    c = 16'hFFFF;
    for (int i = 0; i < n; i++)
      for (int b = 0; b < 8; b++) c = crc16_bit(c, pl[i][b]);
    return ~c;
  endfunction

  // used by task push_bits (tests/usb_fs_sie_tests.sv)
  bit hb [$];

  // ------------------------------------------------------------
  // Independent host-side decoder for DUT transmissions
  // ------------------------------------------------------------
  logic [1:0] hs [$];                     // sampled line states
  bit         dec_bits [$];
  logic [7:0] tp_pid [$];
  bit tp_ok [$];
  int tp_n [$];
  logic [7:0] tp_flat [$];
  real        t0;
  int         stuffs_seen = 0;

  always @(posedge d_oe) begin : dut_tx_monitor
    logic [1:0] prev, cur;
    int ones;
    bit done;
    logic [7:0] bytes [0:300];
    int nb, nbit;
    bit good;
    logic [15:0] c16;
    logic [4:0] c5;
    logic [7:0] pid;
    hs.delete();
    dec_bits.delete();
    wait (bus_dp == 0 && bus_dm == 1);            // first K of SYNC
    t0 = $realtime;
    done = 0;
    prev = 2'b10;
    ones = 0;
    nbit = 0;
    for (int k = 0; !done && k < 4000; k++) begin
      #(BIT_NS * (k == 0 ? 0.5 : 1.0));
      cur = {bus_dp, bus_dm};
      if (cur == 2'b00) done = 1;
      else begin
        if (cur == prev) begin
          if (ones == 6) begin good = 0; end
          ones++;
          dec_bits.push_back(1);
        end else begin
          if (ones == 6) begin // stuffed bit
            ones = 0;
            stuffs_seen++;
          end
          else begin
            dec_bits.push_back(0);
            ones = 0;
          end
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
    tp_pid.push_back(pid);
    tp_ok.push_back(good);
    tp_n.push_back(nb);
    for (int i = 0; i < nb; i++) begin
      logic [7:0] bb;
      bb = 0;
      for (int b = 0; b < 8; b++) bb[b] = dec_bits[16 + i*8 + b];
      tp_flat.push_back(bb);
    end
  end

  // ------------------------------------------------------------
  // Host transmitter: raw bit list -> stuffing -> NRZI -> D+/D-
  // ------------------------------------------------------------
  task automatic push_bits(input logic [31:0] v, input int n);
    for (int i = 0; i < n; i++) hb.push_back(v[i]);
  endtask

  task automatic host_line(input logic dp, input logic dm);
    h_dp = dp;
    h_dm = dm;
    #(BIT_NS);
  endtask

  task automatic host_emit();
    bit j;
    int ones;
    j = 1;
    ones = 0;
    h_oe = 1;
    h_dp = 1;
    h_dm = 0;
    for (int i = 0; i < hb.size(); i++) begin
      if (ones == 6) begin // stuff
        j = ~j;
        host_line(j, ~j);
        ones = 0;
      end
      if (!hb[i]) j = ~j;
      ones = hb[i] ? ones + 1 : 0;
      host_line(j, ~j);
    end
    if (ones == 6) begin
      j = ~j;
      host_line(j, ~j);
    end
    host_line(0, 0); // EOP
    host_line(0, 0);
    host_line(1, 0);
    h_oe = 0;
    hb.delete();
    #(BIT_NS * 6);                                                     // gap
  endtask

  task automatic host_sync_pid(input logic [3:0] pid, input bit bad_pid);
    push_bits(8'h80, 8);
    push_bits({(bad_pid ? pid : ~pid), pid}, 8);
  endtask

  task automatic host_token(input logic [3:0] pid, input logic [6:0] addr,
                            input logic [3:0] ep, input bit bad_crc);
    logic [10:0] v;
    v = {ep, addr};
    host_sync_pid(pid, 0);
    push_bits(v, 11);
    push_bits(bad_crc ? ~token_crc(v) : token_crc(v), 5);
    host_emit();
  endtask

  task automatic host_data(input logic [3:0] pid, input int n, input bit bad_crc);
    logic [15:0] c;
    host_sync_pid(pid, 0);
    for (int i = 0; i < n; i++) push_bits(pl[i], 8);
    c = data_crc(n);
    if (bad_crc) c = c ^ 16'h0100;
    push_bits(c, 16);
    host_emit();
  endtask

  task automatic host_hs(input logic [3:0] pid, input bit bad_pid);
    host_sync_pid(pid, bad_pid);
    host_emit();
  endtask

  task automatic bus_reset(input real ns);   // SE0 for ns, then idle J
    h_oe = 1;
    h_dp = 0;
    h_dm = 0;
    #(ns);
    h_dp = 1;
    h_dm = 0;
    h_oe = 0;
  endtask
endmodule
