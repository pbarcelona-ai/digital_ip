// ***************
// Filename: spi_flash_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the spi_flash_ctrl_tb testbench
//   (spi_flash_ctrl_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check         Counts an error and prints the message when the condition
//                   is false
//     cmd
//     wait_idle     Waits until the DUT is idle
//     flash_status
//     wait_wip
//     test_id_block      ID "SPFL", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                        0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                        offsets from bfm.base = 0x10, the map after the ID block)
//     test_idle          cs_n high, sclk low after reset
//     test_jedec_id      9Fh read ID: EF 40 17, tlast on the last byte; DONE W1C
//     test_page_program  Write enable, read status, page program
//     test_read          Read back with 03h and 0Bh (dummy byte)
//     test_backpressure  Read with m_axis back-pressure
//     test_sector_erase  Sector erase (20h) then the sector reads FF
//     test_no_wel        Program without write enable is ignored; slow source
//                        with page wrap
//     test_busy_cmd      A command while busy is ignored and sets CMD_ERR
//     test_irq           irq_o = DONE & IRQ_EN
//     test_fast_clock    CLKDIV below 3 runs at the minimum half period of 3
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic cmd(input logic [7:0] op, input bit ae, input int dummy, input bit rdd, input bit wrd, input logic [23:0] a, input int len);
    bfm.write(8'h04, {8'd0, a});
    bfm.write(8'h08, len);
    bfm.write(8'h00, {14'd0, wrd, rdd, dummy[3:0], 3'd0, ae, op});
  endtask

  task automatic wait_idle();
    logic [31:0] s;
    do bfm.read(8'h10, s);
    while (s[0]);
  endtask

  task automatic flash_status(output logic [7:0] st);
    rxq.delete();
    cmd(8'h05, 0, 0, 1, 0, 0, 1);
    wait_idle();
    st = rxq.size() ? rxq[0] : 8'hxx;
  endtask

  task automatic wait_wip();
    logic [7:0] s;
    int n;
    n = 0;
    do begin
      flash_status(s);
      n++;
    end
    while (s[0] && n < 200);
    check(n < 200, "WIP never cleared");
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "SPFL", $sformatf("ID %h (\"%s\"), expected \"SPFL\"", id, id));
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

  task automatic test_idle();
    check(spi.cs_n == 1 && spi.sclk == 0, "idle pins");
  endtask

  task automatic test_jedec_id();
    // ---- Test 1: JEDEC ID
    rxq.delete();
    last_seen = 0;
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF && rxq[1] == 8'h40 && rxq[2] == 8'h17 && last_seen, "JEDEC ID mismatch");
    bfm.read(8'h10, rd);
    check(rd[1] == 1 && rd[0] == 0, "done flag");
    bfm.write(8'h10, 32'h2);
    bfm.read(8'h10, rd);
    check(rd[1] == 0, "done W1C");
  endtask

  task automatic test_page_program();
    // ---- Test 2: write enable + status + page program
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    flash_status(st);
    check(st[1] == 1, "WEL not set");
    for (int i = 0; i < 40; i++) begin
      ref_mem[i] = $urandom;
      txq.push_back(ref_mem[i]);
    end
    cmd(8'h02, 1, 0, 0, 1, 24'h001210, 40);
    wait_idle();
    flash_status(st);
    check(st[0] == 1, "WIP after program");
    wait_wip();
    flash_status(st);
    check(st[1:0] == 0, "WEL/WIP after complete");
  endtask

  task automatic test_read();
    // ---- Test 3: read back with 03 and 0B
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 40);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 40, $sformatf("read size %0d", rxq.size()));
    for (int i = 0; i < 40 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i]) begin
      check(0, $sformatf("03 read byte %0d %h exp %h", i, rxq[i], ref_mem[i]));
      i = 40;
    end
    rxq.delete();
    cmd(8'h0B, 1, 1, 1, 0, 24'h001211, 30);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 30, "fast read size");
    for (int i = 0; i < 30 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i+1]) begin
      check(0, $sformatf("0B read byte %0d", i));
      i = 30;
    end
  endtask

  task automatic test_backpressure();
    // ---- Test 4: read with back-pressure
    slow_rx = 1;
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 25);
    wait_idle();
    repeat (20) @(posedge aclk);
    slow_rx = 0;
    check(rxq.size() == 25, $sformatf("backpressure size %0d", rxq.size()));
    for (int i = 0; i < 25 && i < rxq.size(); i++) if (rxq[i] !== ref_mem[i]) begin
      check(0, $sformatf("bp byte %0d", i));
      i = 25;
    end
  endtask

  task automatic test_sector_erase();
    // ---- Test 5: sector erase
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    cmd(8'h20, 1, 0, 0, 0, 24'h001000, 0);
    wait_idle();
    wait_wip();
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h001210, 40);
    wait_idle();
    repeat (3) @(posedge aclk);
    begin
      bit allff;
      allff = 1;
      foreach (rxq[i]) if (rxq[i] !== 8'hFF) allff = 0;
      check(allff && rxq.size() == 40, "sector not erased");
    end
  endtask

  task automatic test_no_wel();
    // ---- Test 6: program without write enable is ignored; slow source with page wrap
    for (int i = 0; i < 8; i++) txq.push_back(8'h11);
    cmd(8'h02, 1, 0, 0, 1, 24'h002000, 8);
    wait_idle();
    wait_wip();
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h002000, 8);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 8 && rxq[0] == 8'hFF, "program without WEL took effect");
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    wait_idle();
    slow_tx = 1;
    for (int i = 0; i < 20; i++) begin
      ref_mem[i] = i + 1;
      txq.push_back(8'(i + 1));
    end
    cmd(8'h02, 1, 0, 0, 1, 24'h0020F0, 20); // crosses the 256 byte page end -> wraps to 0x002000
    wait_idle();
    wait_wip();
    slow_tx = 0;
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h0020F0, 16);
    wait_idle();
    repeat (3) @(posedge aclk);
    for (int i = 0; i < 16; i++) check(rxq[i] === ref_mem[i], $sformatf("page tail byte %0d: %h", i, rxq[i]));
    rxq.delete();
    cmd(8'h03, 1, 0, 1, 0, 24'h002000, 4);
    wait_idle();
    repeat (3) @(posedge aclk);
    for (int i = 0; i < 4; i++) check(rxq[i] === ref_mem[16 + i], $sformatf("page wrap byte %0d: %h exp %h", i, rxq[i], ref_mem[16+i]));
  endtask

  task automatic test_busy_cmd();
    // ---- Test 7: command while busy is ignored, sets cmd_err
    rxq.delete(); // second command while busy
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    bfm.write(8'h00, 32'h0001_0005);
    wait_idle();
    bfm.read(8'h10, rd);
    check(rd[2] == 1, "cmd_err not set");
    check(rxq.size() == 3, "ignored command produced data");
    bfm.write(8'h10, 32'h6);
    bfm.read(8'h10, rd);
    check(rd[2:1] == 0, "flags not cleared");
  endtask

  task automatic test_irq();
    // ---- Test 8: irq
    bfm.write(8'h14, 32'h1);
    cmd(8'h06, 0, 0, 0, 0, 0, 0);
    check(irq == 0, "irq early");
    wait_idle();
    repeat (2) @(posedge aclk);
    check(irq == 1, "irq not raised");
    bfm.write(8'h10, 32'h2);
    repeat (2) @(posedge aclk);
    check(irq == 0, "irq not cleared");
  endtask

  task automatic test_fast_clock();
    // ---- Test 9: faster clock
    bfm.write(8'h0C, 32'd3);
    rxq.delete();
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF, "ID at CLKDIV=3");
    bfm.write(8'h0C, 32'd1);
    rxq.delete();
    cmd(8'h9F, 0, 0, 1, 0, 0, 3);
    wait_idle();
    repeat (3) @(posedge aclk);
    check(rxq.size() == 3 && rxq[0] == 8'hEF, "CLKDIV below minimum not clamped");
  endtask
