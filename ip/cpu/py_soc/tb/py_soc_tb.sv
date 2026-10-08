// ***************
// Filename: py_soc_tb.sv
// Author: FPGA Cores 4 U
// Description: System testbench for py_soc running tb/programs/selftest.py
//   (compiled by py_core/tools/pyc.py into a flash image; see
//   scripts/run_test.sh). The image is loaded into a behavioral SPI NOR
//   flash model and the SoC boots from it. Board wiring - the flash on the
//   boot SPI pins, UART0 TXD -> UART1 RXD and back, each SPI MOSI -> its MISO,
//   I2C0 to a slave model at 0x50 and I2C1 to one at 0x51, GPIO0 pads
//   looped to GPIO1 inputs, GPIO2 inputs driven here. The testbench pulses
//   GPIO2 pins 0 and 31 when the firmware reaches stage 2, then waits for
//   the watchdog reset, checks the firmware's result globals at that
//   moment, and checks that the system boots from flash again and the
//   firmware halts reporting the watchdog as the reset cause. Any core
//   trap fails the test. With +corrupt one payload byte of the image is
//   flipped and the test instead expects boot_err (checksum) and a core
//   that never starts. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module py_soc_tb;
  `include "selftest_syms.svh"
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;   // 100 MHz

  logic [1:0] uart_txd, uart_rxd, scl_i, scl_o, scl_t, sda_i, sda_o, sda_t, sclk, mosi, miso;
  logic [3:0] cs_n; logic [95:0] gpio_i, gpio_o, gpio_t; logic [31:0] gpio2_drv = '0;
  logic done, trap, wdt_reset; logic [33:0] result; logic [3:0] trap_cause; logic [12:0] trap_pc;
  logic boot_done, boot_err; logic [2:0] boot_err_code; logic fl_sclk, fl_cs_n, fl_mosi, fl_miso; int fl_wip;

  py_soc #(.CLK_HZ(100_000_000), .UART_BAUD(2_000_000), .I2C_HZ(2_000_000), .SPI_HZ(10_000_000),
           .FLASH_CLKDIV(3)) dut (
    .clk, .rst_n, .start_i(1'b0), .resume_i(1'b0), .resume_pc_i('0),
    .done_o(done), .result_o(result), .trap_o(trap), .trap_cause_o(trap_cause), .trap_pc_o(trap_pc),
    .boot_done_o(boot_done), .boot_err_o(boot_err), .boot_err_code_o(boot_err_code),
    .flash_sclk_o(fl_sclk), .flash_cs_n_o(fl_cs_n), .flash_mosi_o(fl_mosi), .flash_miso_i(fl_miso),
    .uart_txd_o(uart_txd), .uart_rxd_i(uart_rxd),
    .i2c_scl_i(scl_i), .i2c_scl_o(scl_o), .i2c_scl_t(scl_t), .i2c_sda_i(sda_i), .i2c_sda_o(sda_o), .i2c_sda_t(sda_t),
    .spi_sclk_o(sclk), .spi_mosi_o(mosi), .spi_miso_i(miso), .spi_cs_n_o(cs_n),
    .gpio_i, .gpio_o, .gpio_t, .wdt_reset_o(wdt_reset), .ext_irq_i(4'b0),
    .m_ext_axil_awaddr(), .m_ext_axil_awvalid(), .m_ext_axil_awready(1'b0), .m_ext_axil_wdata(), .m_ext_axil_wstrb(),
    .m_ext_axil_wvalid(), .m_ext_axil_wready(1'b0), .m_ext_axil_bresp(2'b0), .m_ext_axil_bvalid(1'b0), .m_ext_axil_bready(),
    .m_ext_axil_araddr(), .m_ext_axil_arvalid(), .m_ext_axil_arready(1'b0), .m_ext_axil_rdata(32'b0), .m_ext_axil_rresp(2'b0),
    .m_ext_axil_rvalid(1'b0), .m_ext_axil_rready());

  // ---------------- board ----------------
  spi_flash_model flash (.sclk(fl_sclk), .cs_n(fl_cs_n), .mosi(fl_mosi), .miso(fl_miso), .wip_cycles(fl_wip));
  assign uart_rxd = {uart_txd[0], uart_txd[1]};
  assign miso     = mosi;
  assign gpio_i   = {gpio2_drv, gpio_o[31:0], gpio_o[31:0]};
  tri1 sda0, scl0, sda1, scl1;
  assign sda0 = sda_t[0] ? 1'bz : sda_o[0];  assign scl0 = scl_t[0] ? 1'bz : scl_o[0];
  assign sda1 = sda_t[1] ? 1'bz : sda_o[1];  assign scl1 = scl_t[1] ? 1'bz : scl_o[1];
  assign sda_i = {sda1, sda0}; assign scl_i = {scl1, scl0};
  i2c_slave_model #(.ADDR(7'h50)) i2c_dev0 (.sda(sda0), .scl(scl0));
  i2c_slave_model #(.ADDR(7'h51)) i2c_dev1 (.sda(sda1), .scl(scl1));

  // ---------------- firmware globals ----------------
  function automatic longint g(input int idx);
    logic [33:0] v; v = dut.u_core.globals[idx];
    return v[0] ? longint'($signed(v) >>> 1) : -999;        // -999: not a small int
  endfunction

  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; $display("ERROR @%0t: %s", $time, m); end
  endtask

  // Progress log and trap detection
  longint last_stage = -1;
  always @(posedge clk) if (rst_n) begin
    if (g(G_stage) != last_stage) begin last_stage = g(G_stage); $display("[%t] stage %0d", $realtime, last_stage); end
    if (trap) begin
      $display("ERROR @%0t: core trap cause=%0d pc=%0d (see selftest.lst)", $time, trap_cause, trap_pc);
      $display("TEST FAILED"); $finish;
    end
  end

  // Global limit: a stuck boot or firmware fails instead of hanging the run
  initial begin
    #20ms;
    $display("ERROR: simulation timeout in stage %0d (boot_done=%0b boot_err=%0b)", g(G_stage), boot_done, boot_err);
    $display("TEST FAILED"); $finish;
  end

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("py_soc_tb.vcd"); $dumpvars(0, py_soc_tb); end
    $timeformat(-6, 1, " us", 10);
    #1 i2c_dev1.mem[0] = 8'h11; i2c_dev1.mem[1] = 8'h22; i2c_dev1.mem[2] = 8'h33; i2c_dev1.mem[3] = 8'h44;
    $readmemh(`PY_FLASH_HEX, flash.mem);
    if ($test$plusargs("corrupt")) flash.mem[100] = flash.mem[100] ^ 8'h01;
    repeat (5) @(posedge clk); rst_n = 1;

    // ---- boot from flash ----
    fork
      begin wait (boot_done || boot_err); end
      begin repeat (500_000) @(posedge clk); end
    join_any
    disable fork;
    if ($test$plusargs("corrupt")) begin
      check(boot_err && !boot_done && boot_err_code == 3'd3, $sformatf("corrupt image: boot_err=%0b code=%0d", boot_err, boot_err_code));
      repeat (2000) @(posedge clk);
      check(g(G_stage) == -999, "core must not start from a corrupt image");
      if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
      $finish;
    end
    check(boot_done && !boot_err, $sformatf("boot from flash failed, code %0d", boot_err_code));
    $display("[%t] booted from flash: %0d code bytes", $realtime, PROG_BYTES);
    for (int i = 0; i < PROG_BYTES; i++)
      if (dut.code_mem[i] !== flash.mem[12 + i]) begin check(0, $sformatf("code byte %0d differs from flash", i)); break; end

    // Stage 2: rising edges on GPIO2 pins 0 and 31, far enough apart for two interrupts
    while (g(G_stage) != 2) @(posedge clk);
    repeat (50) @(posedge clk);
    gpio2_drv[0] = 1; repeat (300) @(posedge clk);
    gpio2_drv[31] = 1;

    fork
      begin wait (wdt_reset); end
      begin repeat (2_000_000) @(posedge clk); $display("ERROR: timeout waiting for watchdog reset in stage %0d", g(G_stage)); $display("TEST FAILED"); $finish; end
    join_any
    disable fork;

    // Globals are still intact in the clock the watchdog fires
    $display("results: errors=%0d u0=%0d/%0h spi1=%0d/%0h i2c1=%0d/%0h gpio=%0d/%h flash=%0d/%h wdt_pre=%0d",
             g(G_errors), g(G_u0_count), g(G_u0_sum), g(G_spi1_count), g(G_spi1_sum),
             g(G_i2c1_count), g(G_i2c1_sum), g(G_gpio_edges), g(G_gpio_bits), g(G_flash_count), g(G_flash_word), g(G_wdt_pre));
    check(g(G_cause) == 1, $sformatf("first boot reset cause %0d, expected external (1)", g(G_cause)));
    check(g(G_stage) == 12, $sformatf("firmware reached stage %0d before the watchdog fired", g(G_stage)));
    check(g(G_errors) == 0, $sformatf("firmware counted %0d errors", g(G_errors)));
    check(g(G_u0_count) == 16 && g(G_u0_sum) == 'h378, "UART0 interrupt receive of the 16-byte burst");
    check(g(G_spi1_count) == 3 && g(G_spi1_sum) == 'h6666, "SPI1 interrupt receive");
    check(g(G_i2c1_count) == 4 && g(G_i2c1_sum) == 'hAA, "I2C1 interrupt receive");
    check(g(G_gpio_bits) == 'h8000_0001 && g(G_gpio_edges) == 2, "GPIO2 edge interrupts");
    check(g(G_wdt_pre) >= 3, "watchdog pre-timeout interrupts");
    check(g(G_flash_count) == 4 && g(G_flash_word) == 'h3143_5950, "flash interrupt read of the image header");
    check(i2c_dev0.mem[16] == 8'hAA && i2c_dev0.mem[17] == 8'h55, "I2C0 write landed in slave memory");

    // Watchdog reset: the boot loader copies the image from flash again and the firmware starts over
    repeat (5) @(posedge clk);
    check(!boot_done && wdt_reset, "watchdog reset must hold the system and restart the boot loader");
    wait (!wdt_reset);
    fork
      begin wait (done); end
      begin repeat (500_000) @(posedge clk); end
    join_any
    disable fork;
    check(boot_done && done && result == 34'h5,
          $sformatf("after the watchdog reboot the firmware should halt(2): boot_done=%0b done=%0b result=%h", boot_done, done, result));

    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
