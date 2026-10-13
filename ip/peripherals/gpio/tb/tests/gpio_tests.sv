// ***************
// Filename: gpio_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the gpio_tb testbench (gpio_tb.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Register offsets are relative to
//   bfm.base (0x10, the map after the ID block). Tasks, in file order:
//     check          Counts an error and prints the message when the
//                    condition is false
//     test_id_block  ID "GPIO", VERSION ("d.dd") and DATE (BCD mm/dd/yyyy)
//                    at 0x00-0x08, read only; 0x0C reads 0
//     test_reset     Pins reset to inputs, OUT / INT_STATUS read 0
//     test_output    DIR and OUT drive the pins; atomic SET / CLEAR /
//                    TOGGLE; SET / CLEAR / TOGGLE read 0 (write only)
//     test_input     IN reads the two-flop synchronised pin levels
//     test_edge_irq  Rising / falling edge enables, INT_STATUS write 1 to
//                    clear, INT_EN masking of irq_o
//     test_ro_write  A write to IN (read only) answers SLVERR
// Date: 2026-10-12
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin
      errors++;
      $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    bfm.read_abs(8'h0, id);
    bfm.read_abs(8'h4, ver);
    bfm.read_abs(8'h8, date);
    bfm.read_abs(8'hC, rsv);
    check(id == "GPIO", $sformatf("ID %h (\"%s\"), expected \"GPIO\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      bfm.write_abs(8'(a), 32'hA5A5_5A5A);
      check(bfm.last_resp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bfm.last_resp));
    end
    bfm.resp_errors = 0;
    bfm.read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_reset();
    check(gpio_t == '1, "pins should reset to inputs");
    bfm.read(8'h00, rd);
    check(rd == 0, $sformatf("OUT resets to %h", rd));
    bfm.read(8'h24, rd);
    check(rd == 0, $sformatf("INT_STATUS resets to %h", rd));
  endtask

  task automatic test_output();
    bfm.write(8'h04, 32'h0F);                       // low nibble outputs
    bfm.write(8'h00, 32'hA5);
    check(gpio_t == 8'hF0 && gpio_o == 8'hA5, "direction/out");
    bfm.read(8'h00, rd);
    check(rd == 32'hA5, $sformatf("OUT reads %h", rd));
    bfm.write(8'h0C, 32'h0A);
    check(gpio_o == 8'hAF, "set");
    bfm.write(8'h10, 32'h05);
    check(gpio_o == 8'hAA, "clear");
    bfm.write(8'h14, 32'hFF);
    check(gpio_o == 8'h55, "toggle");
    for (int a = 'h0C; a <= 'h14; a += 4) begin
      bfm.read(8'(a), rd);
      check(rd == 0, $sformatf("write-only register 0x%0h reads %h", a + 'h10, rd));
    end
  endtask

  task automatic test_input();
    gpio_i = 8'h3C;
    repeat (4) @(posedge aclk);
    bfm.read(8'h08, rd);
    check(rd == 32'h3C, "input read");
  endtask

  task automatic test_edge_irq();
    // edge interrupts: rise on bit 0 and 6, fall on bit 2
    bfm.write(8'h1C, 32'h41);
    bfm.write(8'h20, 32'h04);
    bfm.write(8'h18, 32'h45);
    gpio_i = 8'h3D; // bit0 rises
    repeat (5) @(posedge aclk);
    check(irq == 1, "irq after rising edge");
    bfm.read(8'h24, rd);
    check(rd == 32'h01, $sformatf("status %h", rd));
    bfm.write(8'h24, 32'h01);
    repeat (3) @(posedge aclk);
    check(irq == 0, "irq not cleared by W1C");
    gpio_i = 8'h39; // bit2 falls
    repeat (5) @(posedge aclk);
    bfm.read(8'h24, rd);
    check(rd == 32'h04, "falling edge status");
    bfm.write(8'h24, 32'h04);
    gpio_i = 8'h79; // bit6 rises
    repeat (5) @(posedge aclk);
    check(irq == 1, "bit 6 (rise enabled) should interrupt");
    bfm.write(8'h18, 32'h00);
    bfm.write(8'h24, 32'hFF);
    repeat (3) @(posedge aclk);
    check(irq == 0, "irq with INT_EN=0");
  endtask

  task automatic test_ro_write();
    bfm.write(8'h08, 32'hFF);
    check(bfm.last_resp == 2'b10, $sformatf("write to IN answered %b, expected SLVERR", bfm.last_resp));
    bfm.resp_errors = 0;
  endtask
