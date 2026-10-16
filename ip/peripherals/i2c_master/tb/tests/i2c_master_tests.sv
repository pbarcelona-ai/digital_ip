// ***************
// Filename: i2c_master_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the i2c_master_tb testbench
//   (i2c_master_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write   AXI4-Lite write of one register (offset from reg_base,
//                  0x10: the map after the ID block); last_bresp keeps BRESP
//     axil_read    AXI4-Lite read of one register (offset from reg_base)
//     axil_write_abs / axil_read_abs  the same at an absolute address
//     stream_send  Sends one AXI4-Stream beat
//     i2c_xfer     Run a transaction and wait for the done flag
//     test_id_block    ID "I2CM", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                      0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_default_div DIV resets to CLK_HZ / (4 * SCL_HZ) - 1 (249: 100 kHz
//                      at 100 MHz), then 12 for a fast simulated bus
//     test_write       Pointer 0x10 and two data bytes written to the EEPROM
//                      model, STOP leaves the bus idle
//     test_repeated_start_read  Pointer write without STOP, repeated START
//                      read of 2 bytes, tlast on the last byte only
//     test_nack        An absent target NACKs the address; STATUS W1C clears
//                      the flags
//     test_probe       Address-only probe (LEN 0) of a present target
//     test_stretch     Read with clock stretching by the target
// Date: 2026-10-12
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  task automatic axil_write(input [7:0] a, input [31:0] d);
    axil_write_abs(a + reg_base, d);
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    axil_read_abs(a + reg_base, d);
  endtask

  task automatic axil_write_abs(input [7:0] a, input [31:0] d);
    @(posedge aclk);
    #1;
    s_axil.awaddr = a;
    s_axil.awvalid = 1;
    s_axil.wdata = d;
    s_axil.wstrb = 4'hF;
    s_axil.wvalid = 1;
    s_axil.bready = 1;
    fork
      begin
        wait (s_axil.awready);
        @(posedge aclk);
        #1 s_axil.awvalid = 0;
      end
      begin
        wait (s_axil.wready);
        @(posedge aclk);
        #1 s_axil.wvalid = 0;
      end
    join
    wait (s_axil.bvalid);
    last_bresp = s_axil.bresp;
    @(posedge aclk);
    #1;
  endtask

  task automatic axil_read_abs(input [7:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    s_axil.araddr = a;
    s_axil.arvalid = 1;
    s_axil.rready = 1;
    wait (s_axil.arready);
    @(posedge aclk);
    #1 s_axil.arvalid = 0;
    wait (s_axil.rvalid);
    d = s_axil.rdata;
    @(posedge aclk);
    #1;
  endtask

  task automatic stream_send(input [7:0] b);
    @(posedge aclk);
    #1;
    s.tdata = b;
    s.tvalid = 1;
    s.tlast = 0;
    wait (s.tready);
    @(posedge aclk);
    #1 s.tvalid = 0;
  endtask

  // Run a transaction and wait for the done flag
  task automatic i2c_xfer(input [6:0] a, input bit read, input int len,
                          input bit nostop);
    axil_write(8'h04, {25'd0, a});
    axil_write(8'h08, len);
    axil_write(8'h10, 32'hE);                           // clear flags
    axil_write(8'h00, {28'd0, nostop, read, 1'b1, 1'b1});
    do axil_read(8'h10, rd); // wait for done
    while (rd[1] == 1'b0);
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "I2CM", $sformatf("ID %h (\"%s\"), expected \"I2CM\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[23:16] == ".", $sformatf("VERSION %h (\"%s\")", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      axil_write_abs(8'(a), 32'hA5A5_5A5A);
      check(last_bresp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, last_bresp));
    end
    axil_read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_default_div();
    axil_read(8'h0C, rd);
    check(rd == 32'd249, $sformatf("default DIV %0d (100 kHz at 100 MHz)", rd));
    axil_write(8'h0C, 32'd12);                          // fast bus for sim
  endtask

  task automatic test_write();
    // ---- Test 1: write pointer 0x10 then two data bytes ----
    stream_send(8'h10);
    stream_send(8'hAA);
    stream_send(8'h55);
    i2c_xfer(7'h50, 0, 3, 0);
    check(rd[2] == 0, "unexpected NACK on write");
    check(slave.mem[16] == 8'hAA && slave.mem[17] == 8'h55,
          $sformatf("slave memory %02h %02h", slave.mem[16], slave.mem[17]));
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after STOP");
  endtask

  task automatic test_repeated_start_read();
    // ---- Test 2: pointer write without STOP, repeated START read ----
    stream_send(8'h10);
    i2c_xfer(7'h50, 0, 1, 1);
    check(scl === 1'b0, "SCL should stay low after no-stop transaction");
    i2c_xfer(7'h50, 1, 2, 0);
    repeat (20) @(posedge aclk);
    check(rx_q.size() == 2, $sformatf("read %0d bytes", rx_q.size()));
    if (rx_q.size() == 2) begin
      check(rx_q[0] == 8'hAA && rx_q[1] == 8'h55, "read data mismatch");
      check(last_q[0] == 0 && last_q[1] == 1, "tlast on final read byte only");
    end
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after read STOP");
    rx_q.delete();
    last_q.delete();
  endtask

  task automatic test_nack();
    // ---- Test 3: absent slave NACKs the address ----
    i2c_xfer(7'h51, 0, 1, 0);
    check(rd[2] == 1, "NACK flag not set");
    stream_send(8'h00);                       // consume unused byte later
    axil_write(8'h10, 32'hE);
    axil_read(8'h10, rd);
    check(rd[3:1] == 0, "W1C did not clear flags");
    check(scl === 1'b1 && sda === 1'b1, "bus not idle after NACK");
  endtask

  task automatic test_probe();
    // ---- Test 4: address-only probe (len = 0) ----
    i2c_xfer(7'h50, 0, 0, 0);
    check(rd[2] == 0, "probe of present slave NACKed");
  endtask

  task automatic test_stretch();
    // ---- Test 5: read with clock stretching ----
    slave.stretch_en = 1;
    i2c_xfer(7'h50, 1, 1, 0);
    repeat (20) @(posedge aclk);
    check(rx_q.size() == 1, "stretched read lost data");
    check(rd[2] == 0, "NACK during stretched transfer");
    slave.stretch_en = 0;
  endtask
