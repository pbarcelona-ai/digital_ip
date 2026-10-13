// ***************
// Filename: dma_engine_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the dma_engine_tb testbench
//   (dma_engine_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check    Counts an error and prints the message when the condition is
//              false
//     run_dma
//     verify
//     test_id_block   ID "DMAE", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                     0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                     offsets from bfm.base = 0x10, the map after the ID block)
//     test_small      Small aligned copy (one burst)
//     test_cross_4k   Source and destination cross 4 KB, length not a burst multiple
//     test_17_words   17-word copy
//     test_bus_error  Destination beyond the memory: SLVERR sets ERROR
//     test_bad_len    An invalid length is rejected
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run_dma(input [31:0] s, input [31:0] d, input [31:0] len);
    bfm.write(8'h04, s);
    bfm.write(8'h08, d);
    bfm.write(8'h0C, len);
    bfm.write(8'h10, 32'h300);                       // clear flags
    bfm.write(8'h00, 32'h3);                         // start + irq_en
    do bfm.read(8'h10, rd);
    while (rd[8] == 0 && rd[9] == 0);
  endtask

  task automatic verify(input [31:0] s, input [31:0] d, input int words, input string tag);
    for (int i = 0; i < words; i++)
      if (mem.mem[d/4 + i] !== mem.mem[s/4 + i]) begin
        errors++;
        $display("ERROR %s: word %0d dst %h src %h", tag, i, mem.mem[d/4+i], mem.mem[s/4+i]);
        i = words;
        end
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "DMAE", $sformatf("ID %h (\"%s\"), expected \"DMAE\"", id, id));
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

  task automatic test_small();
    // ---- Test 1: small aligned copy (one burst) ----
    run_dma(32'h0000_0000, 32'h0000_2000, 32'd64);
    check(rd[8] == 1 && rd[9] == 0, $sformatf("test1 status %h", rd));
    check(irq == 1, "irq");
    verify(32'h0, 32'h2000, 16, "t1");
    check(mem.mem[32'h2000/4 + 16] === 32'hFFFF_FFFF, "t1 overrun past end");
  endtask

  task automatic test_cross_4k();
    // ---- Test 2: both source and destination cross 4 KB, length not a burst multiple ----
    run_dma(32'h0000_0F00, 32'h0000_2F40, 32'd768);
    check(rd[8] == 1 && rd[9] == 0, $sformatf("test2 status %h", rd));
    verify(32'h0F00, 32'h2F40, 192, "t2");
    check(mem.mem[32'h2F40/4 - 1] === 32'hFFFF_FFFF, "t2 underrun before dst");
    check(mem.mem[32'h2F40/4 + 192] === 32'hFFFF_FFFF, "t2 overrun after dst");
  endtask

  task automatic test_17_words();
    // ---- Test 3: 17 words ----
    run_dma(32'h0000_0210, 32'h0000_2100, 32'd68);
    verify(32'h0210, 32'h2100, 17, "t3");
    check(mem.mem[32'h2100/4 + 17] === 32'hFFFF_FFFF, "t3 overrun");
    check(mem.max_awlen <= 15, $sformatf("burst longer than MAX_BURST (%0d)", mem.max_awlen));
  endtask

  task automatic test_bus_error();
    // ---- Test 4: destination beyond memory -> SLVERR -> error flag ----
    run_dma(32'h0000_0000, 32'h0000_3FF0, 32'd64);
    check(rd[9] == 1, $sformatf("test4 error flag %h", rd));
  endtask

  task automatic test_bad_len();
    // ---- Test 5: invalid length is rejected ----
    bfm.write(8'h10, 32'h300);
    bfm.write(8'h0C, 32'd6);
    bfm.write(8'h00, 32'h1);
    repeat (20) @(posedge aclk);
    bfm.read(8'h10, rd);
    check(rd[9] == 1 && rd[0] == 0 && rd[8] == 0, $sformatf("test5 status %h", rd));
    // flags W1C and irq drop
    bfm.write(8'h10, 32'h300);
    bfm.read(8'h10, rd);
    check(rd[9:8] == 0, "W1C");
  endtask
