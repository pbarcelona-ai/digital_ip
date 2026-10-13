// ***************
// Filename: baud_nco_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the baud_nco_tb testbench (baud_nco_tb.sv),
//   moved out of it and `included into that module, so they use its signals,
//   parameters and models directly. Tasks, in file order:
//     check       Counts an error and prints the message when the condition is
//                 false
//     axil_write  (offset from reg_base = 0x10, the map after the ID block;
//                  axil_write_abs / axil_read_abs: absolute, BRESP in last_bresp)
//     axil_write  AXI4-Lite write of one register
//     axil_read   AXI4-Lite read of one register
//     test_id_block       ID "BNCO", VERSION ("d.dd"), DATE (BCD mm/dd/yyyy) at
//                         0x00-0x08, read only (SLVERR); 0x0C reads 0
//     test_default_fcw    FCW resets to 115200 x 16 at 100 MHz; CTRL resets to EN
//     test_baud_tick      16 MHz tick (1 Mbaud x 16) counted by TICK_COUNT
//     test_sine_stream    Sine / cosine stream, quarter cycle offset, gain 0.5
//     test_backpressure   Random back pressure on the stream, full gain
//     test_square         Square wave duty; CTRL readback, PHASE_RST self clears
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

  task automatic test_id_block();
    logic [31:0] id, ver, date, rsv, v;
    axil_read_abs(8'h0, id);
    axil_read_abs(8'h4, ver);
    axil_read_abs(8'h8, date);
    axil_read_abs(8'hC, rsv);
    check(id == "BNCO", $sformatf("ID %h (\"%s\"), expected \"BNCO\"", id, id));
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

  task automatic test_default_fcw();
    // ---- Test 1: default FCW = 115200 * 16 at 100 MHz ----
    axil_read(8'h04, rd);
    check(rd == 32'd79164837, $sformatf("default FCW %0d", rd));
    axil_read(8'h00, rd);
    check(rd[0] == 1, "enabled after reset");
  endtask

  task automatic test_baud_tick();
    // ---- Test 2: baud tick frequency, 16 MHz tick (1 Mbaud x16) ----
    axil_write(8'h14, 0);                    // clear tick counter
    axil_write(8'h04, 32'd687194767);
    repeat (5) @(posedge aclk);
    tick_count = 0;
    repeat (10000) @(posedge aclk);
    check(tick_count >= 1599 && tick_count <= 1601,
          $sformatf("tick count %0d, expected 1600", tick_count));
    axil_read(8'h14, rd);
    check(rd >= 1599, $sformatf("TICK_COUNT reg %0d", rd));
  endtask

  task automatic test_sine_stream();
    // ---- Test 3: sine/cosine stream, quarter cycle offset, gain 0.5 ----
    fcw_m = 32'h0400_0000 + 32'h0000_1234;
    off_m = 16'h4000;
    gain_m = 16384;
    axil_write(8'h00, 32'd0);                // stop
    axil_write(8'h04, fcw_m);
    axil_write(8'h08, off_m);
    axil_write(8'h0C, gain_m);
    n_samples = 0;
    chk_enable = 1;
    axil_write(8'h00, 32'h7);                // en | stream_en | phase reset
    repeat (600) @(posedge aclk);
    check(n_samples >= 590, $sformatf("only %0d samples in 600 clocks", n_samples));
  endtask

  task automatic test_backpressure();
    // ---- Test 4: random back pressure, full gain ----
    axil_write(8'h00, 32'd0);
    chk_enable = 0;
    repeat (4) @(posedge aclk);
    gain_m = 32767;
    off_m = 0;
    fcw_m = 32'h0123_4567;
    axil_write(8'h04, fcw_m);
    axil_write(8'h08, off_m);
    axil_write(8'h0C, gain_m);
    bp_enable = 1;
    n_samples = 0;
    chk_enable = 1;
    axil_write(8'h00, 32'h7);
    repeat (2000) @(posedge aclk);
    check(n_samples > 1000 && n_samples < 1600, $sformatf("bp samples %0d", n_samples));
  endtask

  task automatic test_square();
    // ---- Test 5: square wave and register readback ----
    chk_enable = 0;
    bp_enable = 0;
    axil_write(8'h00, 32'h1);
    axil_write(8'h04, 32'h4000_0000);        // f = clk/4
    repeat (4) @(posedge aclk);
    hi = 0;
    repeat (400) begin
      @(posedge aclk);
      hi += sq;
    end
    check(hi >= 195 && hi <= 205, $sformatf("square duty %0d/400", hi));
    axil_read(8'h00, rd);
    check(rd[2] == 0, "phase reset bit must self clear");
  endtask
