// ***************
// Filename: dsi_bfm.sv
// Author: FPGA Cores 4 U
// Description: Testbench MIPI DSI peripheral (receiver) model on PPI-style
//   lanes (one byte per lane per byte clock with a per-lane valid; lanes
//   aligned, as in a direct loopback). Collects each HS burst, splits it
//   into packets - long packets are the data types with low nibble 9, C, D
//   or E (null / blanking / generic and DCS long writes, pixel streams),
//   all others are short - and checks every header ECC and long-packet
//   checksum (errors counts problems). Every packet is logged with the
//   time its burst started: log_dt / log_vc / log_data (short data or word
//   count) / log_burst (burst number) / log_off (payload offset in pay[]).
// Date: 2026-10-02
`timescale 1ns/1ps
module dsi_bfm #(
  parameter int NL   = 2,
  parameter int MAXP = 4096,                       // packets logged
  parameter int MAXB = 400000                      // payload bytes logged
) (
  input logic            clk,
  input logic [NL*8-1:0] lane_data,
  input logic [NL-1:0]   lane_valid
);
  int errors = 0, npk = 0, nbursts = 0, npay = 0;
  logic [5:0] log_dt [MAXP];
  logic [1:0] log_vc [MAXP];
  logic [15:0] log_data [MAXP];
  int log_burst [MAXP], log_off [MAXP];
  realtime log_t [MAXP];
  byte unsigned pay [MAXB];
  byte unsigned bb [8192];
  int nb = 0;
  bit in_burst = 0;
  realtime t0;

  task automatic err(input string m);
    errors++;
    if (errors < 20) $display("ERROR @%0t dsi_rx: %s", $time, m);
  endtask
  function automatic logic [5:0] ecc6(input logic [23:0] d);
    logic [5:0] p;
    p[0] = d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
    p[1] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
    p[2] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
    p[3] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
    p[4] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
    p[5] = d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
    return p;
  endfunction
  function automatic bit is_long(input logic [5:0] dt);
    return dt[3:0] == 4'h9 || dt[3:0] == 4'hC || dt[3:0] == 4'hD || dt[3:0] == 4'hE;
  endfunction

  always @(posedge clk) begin
    if (|lane_valid) begin
      if (!in_burst) begin
        in_burst = 1;
        nb = 0;
        t0 = $realtime;
      end
      for (int l = 0; l < NL; l++) if (lane_valid[l]) begin
        bb[nb] = lane_data[8*l +: 8];
        nb++;
      end
    end else if (in_burst) begin
      in_burst = 0;
      parse();
      nbursts++;
    end
  end

  task automatic parse();
    int i;
    i = 0;
    while (i + 4 <= nb) begin
      logic [23:0] h;
      logic [5:0] dt;
      logic [15:0] d;
      h = {bb[i+2], bb[i+1], bb[i]};
      dt = h[5:0];
      d = h[23:8];
      if ({2'b00, ecc6(h)} != bb[i+3]) err($sformatf("header ECC %02h exp %02h (DT %02h)", bb[i+3], ecc6(h), dt));
      if (npk < MAXP) begin
        log_dt[npk] = dt;
        log_vc[npk] = h[7:6];
        log_data[npk] = d;
        log_burst[npk] = nbursts;
        log_t[npk] = t0;
        log_off[npk] = npay;
      end
      i += 4;
      if (is_long(dt)) begin
        logic [15:0] c, rc;
        logic [7:0] v;
        if (i + d + 2 > nb) begin
          err($sformatf("long packet DT %02h, WC %0d, runs past the burst", dt, d));
          return;
        end
        c = 16'hFFFF;
        for (int k = 0; k < d; k++) begin
          v = bb[i + k];
          for (int b = 0; b < 8; b++) c = (c >> 1) ^ ((c[0] ^ v[b]) ? 16'h8408 : 16'h0000);
          if (npay < MAXB) begin
            pay[npay] = bb[i + k];
            npay++;
          end
        end
        rc = {bb[i + d + 1], bb[i + d]};
        if (rc != c) err($sformatf("checksum %04h exp %04h (DT %02h)", rc, c, dt));
        i += d + 2;
      end
      npk++;
    end
    if (i != nb) err($sformatf("%0d stray bytes at the end of a burst", nb - i));
  endtask
endmodule
