// ***************
// Filename: sdio_host_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for sdio_host with a behavioral SD
//   card model (CMD0, CMD2 long response, CMD8, CMD13, CMD17 block read,
//   CMD24 block write, R3 response, four 512 byte blocks, 1-bit and 4-bit
//   buses, CRC7/CRC16 generation and checking). Tests command/response of
//   all types, block write then read back in 1-bit and 4-bit mode,
//   streamed data and tlast, corrupted response CRC, corrupted read data
//   CRC (block must be discarded), write CRC error status token, response
//   timeout, data timeout, buf_err cases (command while busy, write
//   without data, bad block size), interrupt output and the W1C status.
//   Prints TEST PASSED on success.
// Date: 2026-09-29
`timescale 1ns/1ps
module sdio_host_tb;
  logic aclk = 0, aresetn = 0; always #5 aclk = ~aclk;
  logic [7:0]  s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready; logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb;
  logic s_axil_wvalid, s_axil_wready, s_axil_bvalid, s_axil_bready; logic [1:0] s_axil_bresp, s_axil_rresp; logic s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  axil_bfm #(.ADDR_W(8)) bfm (.*);
  logic [7:0] txd = 0, rxd; logic txv = 0, txr, rxv, rxr = 1, rxl; logic sd_clk, cmd_o, cmd_oe, irq; logic [3:0] dat_o, dat_oe;
  logic card_cmd = 1, card_cmd_drv = 0; logic [3:0] card_dat = 4'hF, card_dat_drv = 0;
  wire cmd_line = cmd_oe ? cmd_o : (card_cmd_drv ? card_cmd : 1'b1);
  wire [3:0] dat_line = (dat_oe & dat_o) | (~dat_oe & (card_dat_drv & card_dat | ~card_dat_drv));
  sdio_host #(.BUF_BYTES(512)) dut (.aclk, .aresetn, .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready, .s_axil_bresp, .s_axil_bvalid, .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready, .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
    .s_axis_tdata(txd), .s_axis_tvalid(txv), .s_axis_tready(txr), .m_axis_tdata(rxd), .m_axis_tvalid(rxv), .m_axis_tready(rxr), .m_axis_tlast(rxl),
    .sd_clk_o(sd_clk), .cmd_o(cmd_o), .cmd_oe_o(cmd_oe), .cmd_i(cmd_line), .dat_o(dat_o), .dat_oe_o(dat_oe), .dat_i(dat_line), .irq_o(irq));
  int errors = 0; logic [31:0] rd;
  task automatic check(input bit c, input string m); if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end endtask
  // ---------------- card model ----------------
  byte cmem [0:2047]; bit bus4 = 0; bit inj_resp_crc = 0, inj_data_crc = 0, inj_wr_status = 0, no_data = 0; int ncmds = 0;
  function automatic logic [6:0] crc7f(input logic [39:0] d);
    logic [6:0] c; c = 0; for (int i = 39; i >= 0; i--) begin logic fb; fb = c[6] ^ d[i]; c = {c[5:0], 1'b0}; if (fb) c ^= 7'h09; end return c;
  endfunction
  function automatic logic [15:0] crc16f(input logic [15:0] c, input logic b);
    logic fb; fb = c[15] ^ b; return {c[14:0], 1'b0} ^ (fb ? 16'h1021 : 16'h0);
  endfunction
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
  initial begin
    logic [47:0] c; logic [31:0] arg; logic [5:0] idx; logic bad;
    for (int i = 0; i < 2048; i++) cmem[i] = $urandom;
    forever begin
      do @(posedge sd_clk); while (cmd_line !== 1'b0);
      c[47] = 0; for (int i = 46; i >= 0; i--) begin @(posedge sd_clk); c[i] = cmd_line; end
      idx = c[45:40]; arg = c[39:8]; bad = (c[7:1] != crc7f(c[47:8])) || !c[0]; ncmds++;
      if (!bad) case (idx)
        6'd0: ;
        6'd2: begin clk_wait(2); send_bits({2'b00, 6'h3F, 128'hA1B2C3D4_E5F60718_293A4B5C_6D7E8F01}, 136); end
        6'd8: send_short(6'd8, arg, 1);
        6'd41: send_short(6'h3F, 32'hC0FF8000, 0);
        6'd13: send_short(6'd13, 32'h0000_0900, 1);
        6'd17: begin send_short(6'd17, 32'h0000_0900, 1); if (!no_data) send_block(arg[1:0]); end
        6'd24: begin send_short(6'd24, 32'h0000_0900, 1); recv_block(arg[1:0]); end
        default: ;
      endcase
    end
  end
  // ---------------- stream collectors / sources ----------------
  byte rxq[$]; int rx_last = 0;
  always @(posedge aclk) if (rxv && rxr) begin rxq.push_back(rxd); if (rxl) rx_last++; end
  byte src[512];
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
  logic [31:0] st;
  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("sdio_host_tb.vcd"); $dumpvars(0, sdio_host_tb); end
    repeat (4) @(posedge aclk); aresetn = 1; repeat (2) @(posedge aclk);
    bfm.read(8'h2C, rd); check(rd == 32'h0001_0000, "version");
    set_bus(0); repeat (20) @(posedge aclk);
    // ---- commands and responses ----
    cmd(0, 0, 0, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[1] && !st[7:2], $sformatf("CMD0 status %h", st)); bfm.write(8'h18, 32'hFE);
    cmd(8, 1, 0, 0, 32'h1AA); wait_idle(); bfm.read(8'h08, rd); bfm.read(8'h18, st); check(rd == 32'h1AA && st[1] && !st[4], $sformatf("CMD8 resp %h st %h", rd, st)); bfm.write(8'h18, 32'hFE);
    cmd(41, 1, 0, 1, 32'h4000_0000); wait_idle(); bfm.read(8'h08, rd); check(rd == 32'hC0FF8000, $sformatf("R3 resp %h", rd)); bfm.write(8'h18, 32'hFE);
    cmd(2, 2, 0, 1, 0); wait_idle(); begin logic [31:0] r0, r1, r2, r3; bfm.read(8'h08, r0); bfm.read(8'h0C, r1); bfm.read(8'h10, r2); bfm.read(8'h14, r3);
      check({r3, r2, r1, r0} == 128'hA1B2C3D4_E5F60718_293A4B5C_6D7E8F01, "R2 long response"); end
    bfm.write(8'h18, 32'hFE);
    cmd(13, 1, 0, 0, 32'h10000); wait_idle(); bfm.read(8'h08, rd); check(rd == 32'h0900, "R1 resp"); bfm.write(8'h18, 32'hFE);
    // response timeout
    cmd(63, 1, 0, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[3] && !st[1], $sformatf("timeout status %h", st)); bfm.write(8'h18, 32'hFE);
    // response CRC error
    inj_resp_crc = 1; cmd(13, 1, 0, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[4] && !st[1], $sformatf("resp crc status %h", st)); bfm.write(8'h18, 32'hFE); inj_resp_crc = 0;
    // ---- block write / read, 1-bit ----
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    bfm.write(8'h20, 512); feed(512); cmd(24, 1, 2, 0, 1); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st);
    check(st[2] && !st[7:3], $sformatf("write status %h", st)); bfm.write(8'h18, 32'hFE);
    begin bit same; same = 1; for (int i = 0; i < 512; i++) if (cmem[512 + i] !== src[i]) same = 0; check(same, "card memory after 1-bit write"); end
    rxq.delete(); rx_last = 0; cmd(17, 1, 1, 0, 1); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("1-bit read status %h bytes %0d last %0d", st, rxq.size(), rx_last)); bfm.write(8'h18, 32'hFE);
    begin bit same; same = 1; for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0; check(same, "1-bit read data"); end
    // ---- 4-bit ----
    set_bus(1); repeat (10) @(posedge aclk);
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    feed(512); cmd(24, 1, 2, 0, 2); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st); check(st[2] && !st[7:3], $sformatf("4-bit write status %h", st)); bfm.write(8'h18, 32'hFE);
    begin bit same; same = 1; for (int i = 0; i < 512; i++) if (cmem[1024 + i] !== src[i]) same = 0; check(same, "card memory after 4-bit write"); end
    rxq.delete(); rx_last = 0; cmd(17, 1, 1, 0, 2); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("4-bit read status %h bytes %0d", st, rxq.size())); bfm.write(8'h18, 32'hFE);
    begin bit same; same = 1; for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0; check(same, "4-bit read data"); end
    // ---- read data CRC error ----
    inj_data_crc = 1; rxq.delete(); cmd(17, 1, 1, 0, 2); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st);
    check(st[5] && !st[2] && rxq.size() == 0, $sformatf("data crc error status %h bytes %0d", st, rxq.size())); bfm.write(8'h18, 32'hFE); inj_data_crc = 0;
    // ---- write CRC status error ----
    inj_wr_status = 1; feed(512); cmd(24, 1, 2, 0, 3); wait_idle(); repeat (5) @(posedge aclk); bfm.read(8'h18, st); check(st[5], $sformatf("write crc status %h", st)); bfm.write(8'h18, 32'hFE); inj_wr_status = 0;
    // ---- data timeout ----
    bfm.write(8'h24, 300); no_data = 1; cmd(17, 1, 1, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[6] && !st[2], $sformatf("data timeout status %h", st)); bfm.write(8'h18, 32'hFE); no_data = 0; bfm.write(8'h24, 100000);
    // ---- buf_err cases ----
    cmd(24, 1, 2, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[7] && ncmds > 0, "write without data must set buf_err"); bfm.write(8'h18, 32'hFE);
    bfm.write(8'h20, 0); cmd(17, 1, 1, 0, 0); wait_idle(); bfm.read(8'h18, st); check(st[7], "bad block size"); bfm.write(8'h18, 32'hFE); bfm.write(8'h20, 512);
    cmd(13, 1, 0, 0, 0); bfm.write(8'h00, 32'h0000_004D); wait_idle(); bfm.read(8'h18, st); check(st[7] && st[1], $sformatf("command while busy %h", st)); bfm.write(8'h18, 32'hFE);
    // ---- irq ----
    bfm.write(8'h28, 32'h1); cmd(0, 0, 0, 0, 0); check(irq == 0, "irq early"); wait_idle(); repeat (2) @(posedge aclk); check(irq == 1, "irq"); bfm.write(8'h18, 32'h2); repeat (2) @(posedge aclk); check(irq == 0, "irq clear");
    check(bfm.resp_errors == 0, "bus errors");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
  initial begin #60_000_000; $display("TEST FAILED (timeout)"); $finish; end
endmodule
