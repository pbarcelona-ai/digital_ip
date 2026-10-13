// ***************
// Filename: intc_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the intc_tb testbench (intc_tb.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check   Counts an error and prints the message when the condition is
//             false
//     settle
//     test_id_block    ID "INTC", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                      0x00-0x08, read only (SLVERR); 0x0C reads 0 (register
//                      offsets from bfm.base = 0x10, the map after the ID block)
//     test_level       Enabled level source 5 raises irq_o and VECTOR, drops
//                      with the source
//     test_priority    Sources 9 and 3: the lowest index wins
//     test_edge        Edge source 7 latches in PENDING until written with 1
//     test_active_low  ACTIVE_LOW: a low input is asserted
//     test_mask        A source not enabled does not interrupt
//     test_soft_set    SOFT_SET sets a source pending, PENDING W1C clears it
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic settle();
    repeat (6) @(posedge aclk);
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "INTC", $sformatf("ID %h (\"%s\"), expected \"INTC\"", id, id));
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

  task automatic test_level();
    // ---- Test: level source 5
    // level source 5, enabled
    bfm.write(8'h00, 32'h0FFF);
    irq_i[5] = 1;
    settle();
    check(irq == 1, "level irq");
    bfm.read(8'h14, rd);
    check(rd[31] && rd[4:0] == 5, $sformatf("vector %h", rd));
    irq_i[5] = 0;
    settle();
    check(irq == 0, "level irq should drop with source");
  endtask

  task automatic test_priority();
    // ---- Test: priority:
    // priority: sources 9 and 3 -> 3 wins
    irq_i[9] = 1;
    irq_i[3] = 1;
    settle();
    bfm.read(8'h14, rd);
    check(rd[4:0] == 3, "priority lowest index");
    irq_i = 0;
    settle();
  endtask

  task automatic test_edge();
    // ---- Test: edge source 7
    // edge source 7: pulse latches until cleared
    bfm.write(8'h04, 32'h0080);
    irq_i[7] = 1;
    settle();
    irq_i[7] = 0;
    settle();
    check(irq == 1, "edge latch should hold");
    bfm.read(8'h0C, rd);
    check(rd[7] == 1, "pending bit 7");
    bfm.write(8'h0C, 32'h0080);
    settle();
    check(irq == 0, "W1C edge clear");
  endtask

  task automatic test_active_low();
    // ---- Test: active-low source 2
    // active-low source 2 (level)
    bfm.write(8'h08, 32'h0004);
    settle();
    check(irq == 1, "active-low: input low is asserted");
    irq_i[2] = 1;
    settle();
    check(irq == 0, "active-low deasserted when input high");
    irq_i[2] = 0;
    bfm.write(8'h08, 32'h0000);
    settle();
  endtask

  task automatic test_mask();
    // ---- Test: masking
    // masking
    irq_i[14] = 1;
    settle();
    check(irq == 0, "source 14 not enabled");
    bfm.write(8'h00, 32'h4000);
    settle();
    check(irq == 1, "enable 14");
    irq_i[14] = 0;
    bfm.write(8'h00, 32'h0FFF);
  endtask

  task automatic test_soft_set();
    // ---- Test: software interrupt
    // software interrupt on edge source 7
    settle();
    bfm.write(8'h10, 32'h0080);
    settle();
    check(irq == 1, "software set");
    bfm.write(8'h0C, 32'h0080);
    settle();
    check(irq == 0, "software clear");
  endtask
