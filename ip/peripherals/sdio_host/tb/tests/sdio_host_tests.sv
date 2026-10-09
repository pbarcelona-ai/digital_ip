// ***************
// Filename: sdio_host_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the sdio_host_tb testbench (sdio_host_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     clk_wait
//     send_bits
//     send_short
//     drive_dat
//     send_block
//     recv_block
//     feed
//     wait_idle   Waits until the DUT is idle
//     cmd
//     set_bus
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end endtask

  task automatic clk_wait(input int n); repeat (n) @(posedge sd_clk); endtask

  task automatic send_bits(input logic [135:0] bits, input int n);
    for (int i = n - 1; i >= 0; i--) begin @(posedge sd_clk); #1 card_cmd_drv = 1; card_cmd = bits[i]; end
    @(posedge sd_clk); #1 card_cmd_drv = 0;
  endtask

  task automatic send_short(input logic [5:0] idx, input logic [31:0] arg, input bit crc_valid);
    logic [39:0] b; logic [6:0] c; b = {2'b00, idx, arg}; c = crc7f(b); if (inj_resp_crc) c = ~c; if (!crc_valid) c = 7'h7F;
    clk_wait(2); send_bits({88'd0, b, c, 1'b1}, 48);
  endtask

  task automatic drive_dat(input logic [3:0] v);
    @(posedge sd_clk); #1 card_dat_drv = bus4 ? 4'hF : 4'h1; card_dat = v;
  endtask

  task automatic send_block(input int blk);
    logic [15:0] crc [4]; logic [3:0] nib;
    for (int j = 0; j < 4; j++) crc[j] = 0;
    clk_wait(2); drive_dat(4'h0);
    for (int i = 0; i < 512; i++) begin
      logic [7:0] b; b = cmem[blk * 512 + i];
      if (bus4) begin
        nib = b[7:4]; for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], nib[j]); drive_dat(nib);
        nib = b[3:0]; for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], nib[j]); drive_dat(nib);
      end else for (int k = 7; k >= 0; k--) begin crc[0] = crc16f(crc[0], b[k]); drive_dat({3'b111, b[k]}); end
    end
    if (inj_data_crc) crc[0][3] = ~crc[0][3];
    for (int i = 15; i >= 0; i--) drive_dat({crc[3][i], crc[2][i], crc[1][i], crc[0][i]});
    drive_dat(4'hF); @(posedge sd_clk); #1 card_dat_drv = 0;
  endtask

  task automatic recv_block(input int blk);
    logic [15:0] crc [4], rc [4]; logic [7:0] b; logic ok; logic [3:0] n;
    for (int j = 0; j < 4; j++) begin crc[j] = 0; rc[j] = 0; end
    do @(posedge sd_clk); while (dat_line[0] !== 1'b0);                          // start bit
    for (int i = 0; i < 512; i++) begin
      if (bus4) begin
        @(posedge sd_clk); n = dat_line; b[7:4] = n; for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], n[j]);
        @(posedge sd_clk); n = dat_line; b[3:0] = n; for (int j = 0; j < 4; j++) crc[j] = crc16f(crc[j], n[j]);
      end else for (int k = 7; k >= 0; k--) begin @(posedge sd_clk); b[k] = dat_line[0]; crc[0] = crc16f(crc[0], dat_line[0]); end
      cmem[blk * 512 + i] = b;
    end
    for (int i = 0; i < 16; i++) begin @(posedge sd_clk); for (int j = 0; j < 4; j++) rc[j] = {rc[j][14:0], dat_line[j]}; end
    @(posedge sd_clk); ok = (rc[0] == crc[0]) && dat_line[0];
    if (bus4) for (int j = 1; j < 4; j++) ok &= (rc[j] == crc[j]);
    // CRC status token and busy
    clk_wait(1); @(posedge sd_clk); #1 card_dat_drv = 4'h1; card_dat = 4'h0;                 // start
    begin logic [2:0] t; t = (ok && !inj_wr_status) ? 3'b010 : 3'b101;
      for (int i = 2; i >= 0; i--) begin @(posedge sd_clk); #1 card_dat = {3'b111, t[i]}; end end
    @(posedge sd_clk); #1 card_dat = 4'hF;                                                    // end bit
    @(posedge sd_clk); #1 card_dat = 4'h0;                                                    // busy
    clk_wait(40); @(posedge sd_clk); #1 card_dat = 4'hF; @(posedge sd_clk); #1 card_dat_drv = 0;
  endtask

  task automatic feed(input int n);
    for (int i = 0; i < n; i++) begin
      @(posedge aclk); #1 txv = 1; txd = src[i]; while (!txr) begin @(posedge aclk); #1; end
    end
    @(posedge aclk); #1 txv = 0;
  endtask

  task automatic wait_idle(); logic [31:0] s; do bfm.read(8'h18, s); while (s[0]); endtask

  task automatic cmd(input int idx, input int resp, input int dir, input bit nocrc, input logic [31:0] arg);
    bfm.write(8'h04, arg); bfm.write(8'h00, {21'd0, nocrc, dir[1:0], resp[1:0], idx[5:0]});
  endtask

  task automatic set_bus(input bit b4); bus4 = b4; bfm.write(8'h1C, {14'd0, 1'b1, b4, 16'd2}); endtask
