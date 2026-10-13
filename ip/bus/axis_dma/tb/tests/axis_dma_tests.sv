// ***************
// Filename: axis_dma_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the axis_dma_tb testbench (axis_dma_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check      Counts an error and prints the message when the condition is
//                false
//     wait_done  Waits until the DUT reports done
//     test_id_block  ID "ADMA", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                    0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                    offsets from bfm.base = 0x10, the map after the ID block)
//     test_mm2s      MM2S 200 words from 0xF80 (crosses a 4 KB boundary)
//     test_s2mm      S2MM 150 words to 0x2FC0 (crosses a 4 KB boundary)
//     test_loopback  MM2S -> S2MM, memory to memory through the streams
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic wait_done(input int bit_done);
    do bfm.read(8'h14, rd);
    while (rd[bit_done] == 0);
    bfm.write(8'h14, 32'hF00);
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "ADMA", $sformatf("ID %h (\"%s\"), expected \"ADMA\"", id, id));
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

  task automatic test_mm2s();
    // ---- Test 1: MM2S 200 words starting 0xF80 (crosses 4 KB) ----
    bfm.write(8'h04, 32'h0F80);
    bfm.write(8'h08, 32'd800);
    bfm.write(8'h00, 32'h1);
    wait_done(8);
    check(cap.size() == 200, $sformatf("mm2s words %0d", cap.size()));
    for (int i = 0; i < cap.size(); i++) begin
      check(cap[i] === mem.mem[32'h0F80/4 + i], $sformatf("mm2s word %0d", i));
      check(caplast[i] == (i == 199), $sformatf("mm2s tlast at %0d", i));
    end
  endtask

  task automatic test_s2mm();
    // ---- Test 2: S2MM 150 words to 0x2FC0 (crosses 4 KB) ----
    begin
      logic [31:0] exp_q[$];
      exp_q.delete();
      bfm.write(8'h0C, 32'h2FC0);
      bfm.write(8'h10, 32'd600);
      bfm.write(8'h00, 32'h2);
      for (int i = 0; i < 150; i++) begin
        @(posedge aclk);
        #1;
        tb_tdata = $urandom;
        tb_tvalid = 1;
        tb_tlast = (i == 149);
        exp_q.push_back(tb_tdata);
        while (!tb_ready) begin
          @(posedge aclk);
          #1;
        end
        if ($urandom_range(0, 3) == 0) begin
          @(posedge aclk);
          #1 tb_tvalid = 0;
          repeat ($urandom_range(1, 4)) @(posedge aclk);
        end
      end
      @(posedge aclk);
      #1 tb_tvalid = 0;
      wait_done(9);
      for (int i = 0; i < 150; i++) check(mem.mem[32'h2FC0/4 + i] === exp_q[i], $sformatf("s2mm word %0d", i));
      check(mem.mem[32'h2FC0/4 - 1] === 32'hFFFF_FFFF && mem.mem[32'h2FC0/4 + 150] === 32'hFFFF_FFFF, "s2mm outside region");
    end
  endtask

  task automatic test_loopback();
    // ---- Test 3: loopback MM2S -> S2MM (memory to memory through the streams) ----
    loop = 1;
    bfm.write(8'h04, 32'h0100);
    bfm.write(8'h08, 32'd256);
    bfm.write(8'h0C, 32'h2400);
    bfm.write(8'h10, 32'd256);
    bfm.write(8'h00, 32'h3);
    do bfm.read(8'h14, rd);
    while (rd[9] == 0);
    for (int i = 0; i < 64; i++) check(mem.mem[32'h2400/4 + i] === mem.mem[32'h0100/4 + i], $sformatf("loop word %0d", i));
    check(mem.mem[32'h2400/4 + 64] === 32'hFFFF_FFFF, "loop overrun");
    check(rd[11:10] == 0, "error flags set");
  endtask
