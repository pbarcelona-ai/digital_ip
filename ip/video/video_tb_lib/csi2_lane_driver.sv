// ***************
// Filename: csi2_lane_driver.sv
// Author: FPGA Cores 4 U
// Description: Testbench D-PHY lane model. send() distributes the bytes of
//   one HS burst (bbuf[0 .. blen-1], filled by the testbench) over NL lanes (byte i on lane i mod NL), the way a CSI-2
//   transmitter does, and drives lane_data / lane_valid as a D-PHY PPI
//   receiver would present them. Optional per-lane random start skew (up
//   to max_skew byte clocks) and 0..max_junk trailing filler bytes per lane
//   (bytes after the packet end, which the receiver must ignore). Between
//   bursts the lanes idle for gap byte clocks (LP state).
//   Packet building (from the CSI-2 specification): csi_packet() builds a
//   packet with header ECC (and payload CRC-16 for long packets) into
//   csi_pkt, csi_pack_raw10() packs csi_px into csi_pay; csi_crc() and
//   csi_ecc() are the reference functions (csi_crc reproduces the two
//   CRC examples of the specification, checked in csi2_rx_tb). send_pkt()
//   sends csi_pkt as one burst. Called hierarchically from testbenches; no
//   queue is ever passed as an argument (iverilog limitation).
// Date: 2026-10-01
`timescale 1ns/1ps
module csi2_lane_driver #(
  parameter int NL = 2
) (
  input  logic            clk,
  output logic [NL*8-1:0] lane_data,
  output logic [NL-1:0]   lane_valid
);
  localparam int MAXB = 8192;                    // bytes per lane per burst
  int max_skew = 0, max_junk = 0, gap = 8;
  byte unsigned lbuf [NL][MAXB];
  int llen [NL], skew [NL];
  byte unsigned bbuf [NL*MAXB]; int blen = 0;     // burst to send
  initial begin lane_data = '0; lane_valid = '0; end

  // ---------------- CSI-2 packet building
  byte unsigned csi_pay[$];                // payload being built
  byte unsigned csi_pkt[$];                // last packet built
  logic [9:0]   csi_px[$];                 // pixels for csi_pack_raw10
  
  function automatic logic [5:0] csi_ecc(input logic [23:0] d);
    logic [5:0] p;
    p[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    p[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    p[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    p[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    p[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    p[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    return p;
  endfunction
  
  // CRC-16 of csi_pay
  function automatic logic [15:0] csi_crc();
    logic [15:0] c; logic [7:0] v;
    c = 16'hFFFF;
    foreach (csi_pay[i]) begin
      v = csi_pay[i];
      for (int b = 0; b < 8; b++) c = (c >> 1) ^ ((c[0] ^ v[b]) ? 16'h8408 : 16'h0000);
    end
    return c;
  endfunction
  
  // csi_pkt = packet with header {wc, vc, dt}; long packets (dt >= 0x10)
  // carry csi_pay and its CRC. For short packets wc is the data field.
  task automatic csi_packet(input logic [1:0] vc, input logic [5:0] dt, input logic [15:0] wc);
    logic [23:0] h; logic [15:0] c;
    csi_pkt.delete();
    h = {wc, vc, dt};
    csi_pkt.push_back(h[7:0]); csi_pkt.push_back(h[15:8]); csi_pkt.push_back(h[23:16]); csi_pkt.push_back({2'b00, csi_ecc(h)});
    if (dt >= 6'h10) begin
      foreach (csi_pay[i]) csi_pkt.push_back(csi_pay[i]);
      c = csi_crc();
      csi_pkt.push_back(c[7:0]); csi_pkt.push_back(c[15:8]);
    end
  endtask
  
  // csi_pay = RAW10 packing of csi_px (4 pixels -> 5 bytes)
  task automatic csi_pack_raw10();
    logic [9:0] p0, p1, p2, p3;
    csi_pay.delete();
    for (int i = 0; i + 3 < csi_px.size(); i += 4) begin
      p0 = csi_px[i]; p1 = csi_px[i+1]; p2 = csi_px[i+2]; p3 = csi_px[i+3];
      csi_pay.push_back(p0[9:2]); csi_pay.push_back(p1[9:2]); csi_pay.push_back(p2[9:2]); csi_pay.push_back(p3[9:2]);
      csi_pay.push_back({p3[1:0], p2[1:0], p1[1:0], p0[1:0]});
    end
  endtask

  task automatic send_pkt();
    foreach (csi_pkt[i]) bbuf[i] = csi_pkt[i];
    blen = csi_pkt.size();
    send();
  endtask

  task automatic send();
    int len;
    for (int l = 0; l < NL; l++) begin llen[l] = 0; skew[l] = (max_skew > 0) ? $urandom_range(max_skew) : 0; end
    for (int i = 0; i < blen; i++) begin lbuf[i % NL][llen[i % NL]] = bbuf[i]; llen[i % NL]++; end
    for (int l = 0; l < NL; l++) begin
      int j; j = (max_junk > 0) ? $urandom_range(max_junk) : 0;
      repeat (j) begin lbuf[l][llen[l]] = $urandom_range(255); llen[l]++; end
    end
    len = 0;
    for (int l = 0; l < NL; l++) if (skew[l] + llen[l] > len) len = skew[l] + llen[l];
    for (int t = 0; t < len; t++) begin
      @(posedge clk);
      for (int l = 0; l < NL; l++) begin
        int k; k = t - skew[l];
        if (k >= 0 && k < llen[l]) begin lane_data[8*l +: 8] <= lbuf[l][k]; lane_valid[l] <= 1'b1; end
        else begin lane_data[8*l +: 8] <= 8'hxx; lane_valid[l] <= 1'b0; end
      end
    end
    @(posedge clk); lane_valid <= '0;
    repeat (gap) @(posedge clk);
  endtask
endmodule
