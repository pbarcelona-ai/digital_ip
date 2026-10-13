// ***************
// Filename: sdio_host_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the sdio_host_tb testbench (sdio_host_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     feed
//     wait_idle   Waits until the DUT is idle
//     cmd
//     set_bus
//     test_id_block       ID "SDIO", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                         0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                         offsets from bfm.base = 0x10, the map after the ID block)
//     test_setup          1-bit bus, SD clock on
//     test_commands       Commands and responses (none, short, long R2, no CRC,
//                         timeout, CRC error)
//     test_block_1bit     Block write and read back, 1-bit bus
//     test_block_4bit     Block write and read back, 4-bit bus
//     test_read_crc_err   A read block with a data CRC error is discarded
//     test_write_crc_err  Write CRC status error
//     test_data_timeout   Data timeout
//     test_buf_err        BUF_ERR cases (bad BLKSIZE, short buffer, command while busy)
//     test_irq            irq_o from enabled STATUS bits
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic feed(input int n);
    for (int i = 0; i < n; i++) begin
      @(posedge aclk);
      #1 txv = 1;
      txd = src[i];
      while (!txr) begin
        @(posedge aclk);
        #1;
      end
    end
    @(posedge aclk);
    #1 txv = 0;
  endtask

  task automatic wait_idle();
    logic [31:0] s;
    do bfm.read(8'h18, s);
    while (s[0]);
  endtask

  task automatic cmd(input int idx, input int resp, input int dir, input bit nocrc, input logic [31:0] arg);
    bfm.write(8'h04, arg);
    bfm.write(8'h00, {21'd0, nocrc, dir[1:0], resp[1:0], idx[5:0]});
  endtask

  task automatic set_bus(input bit b4);
    card.bus4 = b4;
    bfm.write(8'h1C, {14'd0, 1'b1, b4, 16'd2});
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "SDIO", $sformatf("ID %h (\"%s\"), expected \"SDIO\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_setup();
    set_bus(0);
    repeat (20) @(posedge aclk);
  endtask

  task automatic test_commands();
    // ---- Test: commands and responses ----
    cmd(0, 0, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[1] && !st[7:2], $sformatf("CMD0 status %h", st));
    bfm.write(8'h18, 32'hFE);
    cmd(8, 1, 0, 0, 32'h1AA);
    wait_idle();
    bfm.read(8'h08, rd);
    bfm.read(8'h18, st);
    check(rd == 32'h1AA && st[1] && !st[4], $sformatf("CMD8 resp %h st %h", rd, st));
    bfm.write(8'h18, 32'hFE);
    cmd(41, 1, 0, 1, 32'h4000_0000);
    wait_idle();
    bfm.read(8'h08, rd);
    check(rd == 32'hC0FF8000, $sformatf("R3 resp %h", rd));
    bfm.write(8'h18, 32'hFE);
    cmd(2, 2, 0, 1, 0);
    wait_idle();
    begin
      logic [31:0] r0, r1, r2, r3;
      bfm.read(8'h08, r0);
      bfm.read(8'h0C, r1);
      bfm.read(8'h10, r2);
      bfm.read(8'h14, r3);
      check({r3, r2, r1, r0} == 128'hA1B2C3D4_E5F60718_293A4B5C_6D7E8F01, "R2 long response");
    end
    bfm.write(8'h18, 32'hFE);
    cmd(13, 1, 0, 0, 32'h10000);
    wait_idle();
    bfm.read(8'h08, rd);
    check(rd == 32'h0900, "R1 resp");
    bfm.write(8'h18, 32'hFE);
    // response timeout
    cmd(63, 1, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[3] && !st[1], $sformatf("timeout status %h", st));
    bfm.write(8'h18, 32'hFE);
    // response CRC error
    card.inj_resp_crc = 1;
    cmd(13, 1, 0, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[4] && !st[1], $sformatf("resp crc status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.inj_resp_crc = 0;
  endtask

  task automatic test_block_1bit();
    // ---- Test: block write / read, 1-bit ----
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    bfm.write(8'h20, 512);
    feed(512);
    cmd(24, 1, 2, 0, 1);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3], $sformatf("write status %h", st));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512; i++) if (card.cmem[512 + i] !== src[i]) same = 0;
      check(same, "card memory after 1-bit write");
    end
    rxq.delete();
    rx_last = 0;
    cmd(17, 1, 1, 0, 1);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("1-bit read status %h bytes %0d last %0d", st, rxq.size(), rx_last));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0;
      check(same, "1-bit read data");
    end
  endtask

  task automatic test_block_4bit();
    // ---- Test: 4-bit ----
    set_bus(1);
    repeat (10) @(posedge aclk);
    for (int i = 0; i < 512; i++) src[i] = $urandom;
    feed(512);
    cmd(24, 1, 2, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3], $sformatf("4-bit write status %h", st));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512; i++) if (card.cmem[1024 + i] !== src[i]) same = 0;
      check(same, "card memory after 4-bit write");
    end
    rxq.delete();
    rx_last = 0;
    cmd(17, 1, 1, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[2] && !st[7:3] && rxq.size() == 512 && rx_last == 1, $sformatf("4-bit read status %h bytes %0d", st, rxq.size()));
    bfm.write(8'h18, 32'hFE);
    begin
      bit same;
      same = 1;
      for (int i = 0; i < 512 && i < rxq.size(); i++) if (rxq[i] !== src[i]) same = 0;
      check(same, "4-bit read data");
    end
  endtask

  task automatic test_read_crc_err();
    // ---- Test: read data CRC error ----
    card.inj_data_crc = 1;
    rxq.delete();
    cmd(17, 1, 1, 0, 2);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[5] && !st[2] && rxq.size() == 0, $sformatf("data crc error status %h bytes %0d", st, rxq.size()));
    bfm.write(8'h18, 32'hFE);
    card.inj_data_crc = 0;
  endtask

  task automatic test_write_crc_err();
    // ---- Test: write CRC status error ----
    card.inj_wr_status = 1;
    feed(512);
    cmd(24, 1, 2, 0, 3);
    wait_idle();
    repeat (5) @(posedge aclk);
    bfm.read(8'h18, st);
    check(st[5], $sformatf("write crc status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.inj_wr_status = 0;
  endtask

  task automatic test_data_timeout();
    // ---- Test: data timeout ----
    bfm.write(8'h24, 300);
    card.no_data = 1;
    cmd(17, 1, 1, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[6] && !st[2], $sformatf("data timeout status %h", st));
    bfm.write(8'h18, 32'hFE);
    card.no_data = 0;
    bfm.write(8'h24, 100000);
  endtask

  task automatic test_buf_err();
    // ---- Test: buf_err cases ----
    cmd(24, 1, 2, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7] && card.ncmds > 0, "write without data must set buf_err");
    bfm.write(8'h18, 32'hFE);
    bfm.write(8'h20, 0);
    cmd(17, 1, 1, 0, 0);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7], "bad block size");
    bfm.write(8'h18, 32'hFE);
    bfm.write(8'h20, 512);
    cmd(13, 1, 0, 0, 0);
    bfm.write(8'h00, 32'h0000_004D);
    wait_idle();
    bfm.read(8'h18, st);
    check(st[7] && st[1], $sformatf("command while busy %h", st));
    bfm.write(8'h18, 32'hFE);
  endtask

  task automatic test_irq();
    // ---- Test: irq ----
    bfm.write(8'h28, 32'h1);
    cmd(0, 0, 0, 0, 0);
    check(irq == 0, "irq early");
    wait_idle();
    repeat (2) @(posedge aclk);
    check(irq == 1, "irq");
    bfm.write(8'h18, 32'h2);
    repeat (2) @(posedge aclk);
    check(irq == 0, "irq clear");
  endtask
