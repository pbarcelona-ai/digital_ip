// ***************
// Filename: reset_ctrl_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the reset_ctrl_tb testbench
//   (reset_ctrl_tb.sv), moved out of it and `included into that module, so
//   they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check        Counts an error and prints the message when the condition
//                  is false
//     axil_write  (offset from reg_base = 0x10, the map after the ID block;
//                  axil_write_abs / axil_read_abs: absolute, BRESP in last_bresp)
//     axil_write   AXI-Lite master tasks
//     axil_read    AXI4-Lite read of one register
//     measure_low  Count consecutive cycles rst_o[0] stays asserted (low)
//     test_power_up     Power-up: asynchronous assertion, synchronous release
//                       after the stages and the hold
//     test_id_block     ID "RSTC", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                       0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_glitch       A sub-clock glitch is stretched to >= HOLD clocks
//     test_registers    HOLD default and write, sticky EVENT (W1C), EVENT_COUNT
//     test_soft_reset   CTRL soft reset: every copy asserts, held for HOLD, counted
//     test_out_of_range An access beyond the map answers an error
// Date: 2026-10-12
// ***************
  task automatic check(input bit cond, input string msg);
    if (!cond) begin
      errors++;
      $display("ERROR @%0t: %s", $time, msg);
    end
  endtask

  // ---------------- AXI-Lite master tasks ----------------
  task automatic axil_write(input [7:0] a, input [31:0] d);
    axil_write_abs(a + reg_base, d);
    check(last_bresp == 2'b00, "write response not OKAY");
  endtask

  task automatic axil_read(input [7:0] a, output [31:0] d);
    axil_read_abs(a + reg_base, d);
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
    last_bresp = bresp;
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

  // Count consecutive cycles rst_o[0] stays asserted (low)
  task automatic measure_low();
    low_cycles = 0;
    while (rst_o[0] == 1'b0) begin
      @(posedge aclk);
      low_cycles++;
    end
  endtask

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "RSTC", $sformatf("ID %h (\"%s\"), expected \"RSTC\"", id, id));
    check(ver == dut.u_regs.IP_VERSION && ver[31:24] >= "0" && ver[31:24] <= "9" && ver[23:16] == "." &&
          ver[15:8] >= "0" && ver[15:8] <= "9" && ver[7:0] >= "0" && ver[7:0] <= "9",
          $sformatf("VERSION %h (\"%s\"), expected \"d.dd\"", ver, ver));
    check(date == dut.u_regs.IP_DATE && date[31:24] >= 8'h01 && date[31:24] <= 8'h12 &&
          date[23:16] >= 8'h01 && date[23:16] <= 8'h31 && date[15:0] >= 16'h2000,
          $sformatf("DATE %h, expected a BCD mm/dd/yyyy date", date));
    check(rsv == 0, $sformatf("0x0C reads %h, expected 0", rsv));
    for (int a = 0; a < 16; a += 4) begin               // ID / VERSION / DATE: SLVERR, reserved: OKAY
      axil_write_abs(8'(a), 32'hA5A5_5A5A);
      check(last_bresp == ((a < 12) ? 2'b10 : 2'b00), $sformatf("write to 0x%0h answered %b", a, last_bresp));
    end

    axil_read_abs(8'h0, v);
    check(v == id, "ID changed by a write");
  endtask

  task automatic test_power_up();
    // ---- Test 1: power-up async reset and synchronous release ----
    arst_i = 0; // asserted before any clock edge
    #3;
    check(rst_o == '0, "outputs not asserted asynchronously");
    #47 arst_i = 1;                       // release (active low input)
    repeat (3) @(posedge aclk);
    check(rst_o == '0, "reset released too early (sync stages)");
    repeat (4 + HOLD) @(posedge aclk);
    check(rst_o == '1, "reset did not release after stretch");
    check(bus_rst_n == 1'b1, "bus reset stuck");
  endtask

  task automatic test_glitch();
    // ---- Test 2: sub-clock glitch is stretched to >= HOLD cycles ----
    #(CLK_PERIOD*3 + 2.5);
    arst_i = 0; // 1 ns glitch
    #1.0 arst_i = 1;
    #0.1 check(rst_o == '0, "glitch not caught asynchronously");
    measure_low();
    check(low_cycles >= HOLD, $sformatf("glitch pulse %0d < HOLD %0d", low_cycles, HOLD));
    repeat (8) @(posedge aclk);
  endtask

  task automatic test_registers();
    // ---- Test 3: register access ----
    axil_read(8'h04, rd);
    check(rd == HOLD, "HOLD default readback");
    axil_write(8'h04, 32'd8);
    axil_read(8'h04, rd);
    check(rd == 8, "HOLD write/readback");
    axil_read(8'h08, rd);
    check(rd[1] == 1'b1, "sticky event flag should be set by glitch");
    axil_write(8'h08, 32'h2);             // W1C
    axil_read(8'h08, rd);
    check(rd[1] == 1'b0, "sticky flag not cleared by W1C");
    axil_read(8'h0C, rd);
    check(rd >= 1, "event counter should have counted the glitch");
  endtask

  task automatic test_soft_reset();
    // ---- Test 4: software reset ----
    begin
      logic [31:0] cnt0;
      axil_read(8'h0C, cnt0);
      axil_write(8'h00, 32'd1);
      wait (rst_o[0] == 1'b0);
      check(rst_o == '0, "all copies must assert together");
      measure_low();
      check(low_cycles >= 8, "soft reset shorter than HOLD");
      repeat (6) @(posedge aclk);
      axil_read(8'h0C, rd);
      check(rd == cnt0 + 1, "event counter did not increment on soft reset");
      axil_read(8'h08, rd);
      check(rd[1] == 1'b1 && rd[0] == 1'b0, "status after soft reset");
    end
  endtask

  task automatic test_out_of_range();
    // ---- Test 5: an access beyond the map returns an error (DECERR) ----
    axil_read(8'h40, rd);
    check(rresp[1] == 1'b1, $sformatf("expected an error response for an out-of-range read, got %b", rresp));
  endtask
