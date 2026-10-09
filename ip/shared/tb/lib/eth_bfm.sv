// ***************
// Filename: eth_bfm.sv
// Author: FPGA Cores 4 U
// Description: Ethernet GMII PHY bus functional model, connected to a
//   MAC's GMII transmit and receive ports.
//   Transmit monitor: every frame the MAC sends (tx_en high) is appended
//   byte for byte (preamble, SFD, data, FCS) to wire_data, its length to
//   wire_len; min_gap is the shortest idle gap seen between frames.
//   Receive side: loop = 1 returns the MAC's transmit stream (rx_dv =
//   tx_en); with flip = 1, byte flip_at of each looped frame gets bit 4
//   inverted (CRC error injection). loop = 0: send_frame() sends a frame of
//   n random data bytes plus its FCS after preamble and SFD, with rx_er at
//   byte er_at (-1: none); the bytes are left in cq. crc_model(n) is the
//   Ethernet CRC-32 (FCS) of the first n bytes of cq.
// Date: 2026-10-09
`timescale 1ns/1ps

module eth_bfm (
  input  logic       clk,                     // GMII clock (125 MHz)
  input  logic [7:0] txd,                     // MAC gmii_txd
  input  logic       tx_en,
  input  logic       tx_er,
  output logic [7:0] rxd,                     // MAC gmii_rxd
  output logic       rx_dv,
  output logic       rx_er
);
  bit         loop = 1;                       // receive = transmit stream
  bit         flip = 0;                       // invert bit 4 of looped byte flip_at
  int         flip_at = 40;
  logic [7:0] inj_d = 0;
  logic       inj_dv = 0, inj_er = 0;
  int         wire_n = 0;                     // byte index of the looped frame
  assign rxd   = loop ? ((flip && wire_n == flip_at) ? (txd ^ 8'h10) : txd) : inj_d;
  assign rx_dv = loop ? tx_en : inj_dv;
  assign rx_er = loop ? 1'b0 : inj_er;

  // ---------------- CRC-32 over the first n bytes of cq (Icarus cannot pass queues to functions) ----------------
  byte cq[$];
  function automatic logic [31:0] crc_model(input int n);
    logic [31:0] r;
    r = 32'hFFFF_FFFF;
    for (int i = 0; i < n; i++) begin
      r ^= (int'(cq[i]) & 255);
      for (int b = 0; b < 8; b++) r = r[0] ? (r >> 1) ^ 32'hEDB88320 : (r >> 1);
    end
    return ~r;
  endfunction

  // ---------------- transmit monitor (flat byte queue plus length queue) ----------------
  byte wire_data[$];
  int  wire_len[$];
  int  wcur = 0, gap = 100, min_gap = 1000;
  bit  in_frame = 0;
  always @(posedge clk) begin
    if (tx_en === 1'b1) begin
      wire_data.push_back(txd);
      wcur++;
      if (!in_frame) begin
        in_frame = 1;
        if (gap < min_gap) min_gap = gap;
      end
      gap = 0;
    end else begin
      if (in_frame) begin
        in_frame = 0;
        wire_len.push_back(wcur);
        wcur = 0;
      end
      gap++;
    end
    if (loop) wire_n = (tx_en === 1'b1) ? wire_n + 1 : 0;
  end

  // ---------------- receive frame injection (loop = 0) ----------------
  task automatic send_frame(input int n, input int er_at);
    logic [31:0] c;
    cq.delete();
    for (int i = 0; i < n; i++) cq.push_back($urandom);
    c = crc_model(n);
    for (int i = 0; i < 4; i++) cq.push_back(c[i*8 +: 8]);
    for (int i = 0; i < 8; i++) begin
      #1 inj_d = (i == 7) ? 8'hD5 : 8'h55;
      inj_dv = 1;
      @(posedge clk);
    end
    for (int i = 0; i < n + 4; i++) begin
      #1 inj_d = cq[i];
      inj_dv = 1;
      inj_er = (i == er_at);
      @(posedge clk);
    end
    #1 inj_dv = 0;
    inj_er = 0;
    repeat (20) @(posedge clk);
  endtask
endmodule
