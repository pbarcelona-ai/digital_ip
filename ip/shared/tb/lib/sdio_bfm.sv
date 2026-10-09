// ***************
// Filename: sdio_bfm.sv
// Author: FPGA Cores 4 U
// Description: SD card bus functional model for an SD / SDIO host, plus the
//   pulled-up CMD and DAT[3:0] bus between host and card (cmd_line,
//   dat_line: the host drives where its output enable is set, the card
//   where it drives, otherwise the pull-ups). The card decodes every
//   command (CRC7 checked) and answers CMD2 (R2 CID), CMD8, CMD13, ACMD41
//   (R3, no CRC), CMD17 (R1, then one 512-byte block read from cmem) and
//   CMD24 (R1, then receives one block into cmem, CRC16 checked, CRC status
//   token and busy). bus4 selects 4-bit data transfers. Error injection:
//   inj_resp_crc (wrong response CRC), inj_data_crc (wrong read data CRC),
//   inj_wr_status (negative CRC status), no_data (no read data).
//   ncmds counts the commands received.
// Date: 2026-10-09
`timescale 1ns/1ps

module sdio_bfm (
  input  logic       sd_clk,
  input  logic       cmd_o,                   // host CMD output and enable
  input  logic       cmd_oe,
  input  logic [3:0] dat_o,                   // host DAT outputs and enables
  input  logic [3:0] dat_oe,
  output wire        cmd_line,                // resolved bus: to the host inputs
  output wire  [3:0] dat_line
);
  logic card_cmd = 1, card_cmd_drv = 0;
  logic [3:0] card_dat = 4'hF, card_dat_drv = 0;
  assign cmd_line = cmd_oe ? cmd_o : (card_cmd_drv ? card_cmd : 1'b1);
  assign dat_line = (dat_oe & dat_o) | (~dat_oe & (card_dat_drv & card_dat | ~card_dat_drv));

  // ---------------- card model ----------------
  byte cmem [0:2047];
  bit bus4 = 0;
  bit inj_resp_crc = 0, inj_data_crc = 0, inj_wr_status = 0, no_data = 0;
  int ncmds = 0;
  function automatic logic [6:0] crc7f(input logic [39:0] d);
    logic [6:0] c;
    c = 0;
    for (int i = 39; i >= 0; i--) begin
      logic fb;
      fb = c[6] ^ d[i];
      c = {c[5:0], 1'b0};
      if (fb) c ^= 7'h09;
    end
    return c;
  endfunction
  function automatic logic [15:0] crc16f(input logic [15:0] c, input logic b);
    logic fb;
    fb = c[15] ^ b;
    return {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0);
  endfunction
  initial begin
    logic [47:0] c;
    logic [31:0] arg;
    logic [5:0] idx;
    logic bad;
    for (int i = 0; i < 2048; i++) cmem[i] = $urandom;
    forever begin
      do @(posedge sd_clk);
      while (cmd_line !== 1'b0);
      c[47] = 0;
      for (int i = 46; i >= 0; i--) begin
        @(posedge sd_clk);
        c[i] = cmd_line;
      end
      idx = c[45:40];
      arg = c[39:8];
      bad = (c[7:1] != crc7f(c[47:8])) || !c[0];
      ncmds++;
      if (!bad) case (idx)
        6'd0: ;
        6'd2: begin
          clk_wait(2);
          send_bits({2'b00, 6'h3F, 128'hA1B2C3D4_E5F60718_293A4B5C_6D7E8F01}, 136);
        end
        6'd8: send_short(6'd8, arg, 1);
        6'd41: send_short(6'h3F, 32'hC0FF8000, 0);
        6'd13: send_short(6'd13, 32'h0000_0900, 1);
        6'd17: begin
          send_short(6'd17, 32'h0000_0900, 1);
          if (!no_data) send_block(arg[1:0]);
        end
        6'd24: begin
          send_short(6'd24, 32'h0000_0900, 1);
          recv_block(arg[1:0]);
        end
        default: ;
      endcase
    end
  end

  task automatic clk_wait(input int n);
    repeat (n) @(posedge sd_clk);
  endtask

  task automatic send_bits(input logic [135:0] bits, input int n);
    for (int i = n - 1; i >= 0; i--) begin
      @(posedge sd_clk);
      #1 card_cmd_drv = 1;
      card_cmd = bits[i];
    end
    @(posedge sd_clk);
    #1 card_cmd_drv = 0;
  endtask

  task automatic send_short(input logic [5:0] idx, input logic [31:0] arg, input bit crc_valid);
    logic [39:0] b;
    logic [6:0] c;
    b = {2'b00, idx, arg};
    c = crc7f(b);
    if (inj_resp_crc) c = ~c;
    if (!crc_valid) c = 7'h7F;
    clk_wait(2);
    send_bits({88'd0, b, c, 1'b1}, 48);
  endtask

  task automatic drive_dat(input logic [3:0] v);
    @(posedge sd_clk);
    #1 card_dat_drv = bus4 ? 4'hF : 4'h1;
    card_dat = v;
  endtask

  task automatic send_block(input int blk);
    logic [15:0] crc [4];
    logic [3:0] nib;
    for (int j = 0; j < 4; j++) crc[j] = 0;
    clk_wait(2);
    drive_dat(4'h0);
    for (int i = 0; i < 512; i++) begin
      logic [7:0] b;
      b = cmem[blk * 512 + i];
      if (bus4) begin
        nib = b[7:4];
        for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], nib[j]);
        drive_dat(nib);
        nib = b[3:0];
        for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], nib[j]);
        drive_dat(nib);
      end else for (int k = 7; k >= 0; k--) begin
        crc[0] = crc16f(crc[0], b[k]);
        drive_dat({3'b111, b[k]});
      end
    end
    if (inj_data_crc) crc[0][3] = ~crc[0][3];
    for (int i = 15; i >= 0; i--) drive_dat({crc[3][i], crc[2][i], crc[1][i], crc[0][i]});
    drive_dat(4'hF);
    @(posedge sd_clk);
    #1 card_dat_drv = 0;
  endtask

  task automatic recv_block(input int blk);
    logic [15:0] crc [4], rc [4];
    logic [7:0] b;
    logic ok;
    logic [3:0] n;
    for (int j = 0; j < 4; j++) begin
      crc[j] = 0;
      rc[j] = 0;
    end
    do @(posedge sd_clk); // start bit
    while (dat_line[0] !== 1'b0);
    for (int i = 0; i < 512; i++) begin
      if (bus4) begin
        @(posedge sd_clk);
        n = dat_line;
        b[7:4] = n;
        for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], n[j]);
        @(posedge sd_clk);
        n = dat_line;
        b[3:0] = n;
        for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], n[j]);
      end else for (int k = 7; k >= 0; k--) begin
        @(posedge sd_clk);
        b[k] = dat_line[0];
        crc[0] = crc16f(crc[0], dat_line[0]);
      end
      cmem[blk * 512 + i] = b;
    end
    for (int i = 0; i < 16; i++) begin
      @(posedge sd_clk);
      for (int j = 0; j < 4; j++) rc[j] = {rc[j][14:0], dat_line[j]};
    end
    @(posedge sd_clk);
    ok = (rc[0] == crc[0]) && dat_line[0];
    if (bus4) for (int j = 1; j < 4; j++) ok &= (rc[j] == crc[j]);
    // CRC status token and busy
    clk_wait(1); // start
    @(posedge sd_clk);
    #1 card_dat_drv = 4'h1;
    card_dat = 4'h0;
    begin
      logic [2:0] t;
      t = (ok && !inj_wr_status) ? 3'b010 : 3'b101;
      for (int i = 2; i >= 0; i--) begin
        @(posedge sd_clk);
        #1 card_dat = {3'b111, t[i]};
      end
    end
    @(posedge sd_clk); // end bit
    #1 card_dat = 4'hF;
    @(posedge sd_clk); // busy
    #1 card_dat = 4'h0;
    clk_wait(40);
    @(posedge sd_clk);
    #1 card_dat = 4'hF;
    @(posedge sd_clk);
    #1 card_dat_drv = 0;
  endtask
endmodule
