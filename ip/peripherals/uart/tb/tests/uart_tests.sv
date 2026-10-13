// ***************
// Filename: uart_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the uart_tb testbench (uart_tb.sv), moved out
//   of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     test_id_block        ID "UART", VERSION ("d.dd") and DATE (BCD
//                          mm/dd/yyyy) at the base address, read only
//                          (SLVERR); the rest of the map from 0x10
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write   AXI4-Lite write of one register
//     axil_read    AXI4-Lite read of one register
//     stream_send  AXI-Stream helpers
//     serial_send  Serial driver (acts as external transmitter)
// Date: 2026-10-08
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  task automatic axil_write_abs(input [7:0] a, input [31:0] d);
    @(posedge aclk);
    #1;
    awaddr = a;
    awvalid = 1;
    wdata = d;
    wstrb = 4'hF;
    wvalid = 1;
    bready = 1;
    fork
      begin
        wait (awready);
        @(posedge aclk);
        #1 awvalid = 0;
      end
      begin
        wait (wready);
        @(posedge aclk);
        #1 wvalid = 0;
      end
    join
    wait (bvalid);
    @(posedge aclk);
    #1;
  endtask

  task automatic axil_read_abs(input [7:0] a, output [31:0] d);
    @(posedge aclk);
    #1;
    araddr = a;
    arvalid = 1;
    rready = 1;
    wait (arready);
    @(posedge aclk);
    #1 arvalid = 0;
    wait (rvalid);
    d = rdata;
    @(posedge aclk);
    #1;
  endtask

  // ---------- AXI-Stream helpers ----------
  task automatic stream_send(input [7:0] b);
    @(posedge aclk);
    #1;
    s_tdata = b;
    s_tvalid = 1;
    s_tlast = 0;
    wait (s_tready);
    @(posedge aclk);
    #1 s_tvalid = 0;
  endtask

  // ---------- Serial driver (acts as external transmitter) ----------
  task automatic serial_send(input [7:0] b, input int nbits, input bit pen,
                             input bit podd, input bit stop2,
                             input bit bad_par, input bit bad_stop);
    uart.send_frame(b, nbits, pen, podd, stop2, bad_par, bad_stop);
  endtask

  // register offset of the map after the ID block (reg_base)
  task automatic axil_write(input [7:0] a, input [31:0] d);
    axil_write_abs(8'(a + reg_base), d);
  endtask

  // register offset of the map after the ID block (reg_base)
  task automatic axil_read(input [7:0] a, output [31:0] d);
    axil_read_abs(8'(a + reg_base), d);
  endtask

  // ID block at the base address: ID, VERSION (ASCII "d.dd"), DATE (BCD mm/dd/yyyy), 0x0C reserved;
  // read only (writes answer SLVERR); the rest of the map starts at 0x10 (reg_base)
  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "UART", $sformatf("ID %h (\"%s\"), expected \"UART\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\" = \"%s\"", ver, ver, dut.u_regs.IP_VERSION));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 && date[27:24] <= 9 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[19:16] <= 9 && date[15:0] >= 16'h2000 &&
          date[15:12] <= 9 && date[11:8] <= 9 && date[7:4] <= 9 && date[3:0] <= 9,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date = %h", date, dut.u_regs.IP_DATE));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      axil_write_abs(8'(a), 32'hA5A5_5A5A);
      check(bresp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, bresp));
    end
    axil_read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
    axil_read_abs(8'h4, v);
    check(v == ver, "VERSION changed by a write");
    axil_read_abs(8'h8, v);
    check(v == date, "DATE changed by a write");
    $display("[%0t] test_id_block: ID \"%s\", VERSION \"%s\", DATE %0h/%0h/%0h", $time, id, ver, date[31:24],
             date[23:16], date[15:0]);
  endtask
