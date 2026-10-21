// ***************
// Filename: py_soc_cocotb_top.sv
// Author: FPGA Cores 4 U
// Description: cocotb wrapper of py_soc for the system comparison with its
//   model (py_soc_tb.py: py_soc_model Soc + py_boot_model + py_core_model).
//   py_soc (u_soc) as in the SystemVerilog testbench tb/py_soc_tb.sv:
//   100 MHz, UART 2 Mbaud, I2C 2 MHz, SPI 10 MHz, FLASH_CLKDIV 3, no clock
//   generator, the DDR and EXT windows decoded. Board wiring (the model's
//   board in py_soc_tb.py is the same) - the boot flash (spi_flash_bfm,
//   loaded from +FLASH=<hex>), UART0 TXD -> UART1 RXD and back, each SPI
//   MOSI -> its MISO, I2C0 to a target at 0x50 and I2C1 to one at 0x51
//   (i2c_bfm; 0x51 holds 11 22 33 44 from address 0), GPIO0 outputs on the
//   GPIO0 and GPIO1 inputs, the GPIO2 inputs from gpio2_i, ext_irq_i to the
//   intc sources 12-15; the EXT and DDR windows each on a behavioral
//   AXI4-Lite memory (ready while both AW and W / AR are valid, the
//   response the clock after: py_axil_xbar_model's default timing) of 256
//   words, word index {addr[15] / addr[25], addr[8:2]} (the bottom and the
//   top of the window), zero at time 0. The test reads py_soc's internal
//   state (u_soc.sys_rst_n, u_soc.u_core.st / ipc, the core's bus).
//   Clock - clk. Reset - rst_n (synchronous, active low).
// Date: 2026-10-20
`timescale 1ns/1ps
module py_soc_cocotb_top (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] gpio2_i,
  input  logic [3:0]  ext_irq_i,
  output logic        boot_done_o,
  output logic        boot_err_o,
  output logic        done_o,
  output logic        trap_o,
  output logic [3:0]  trap_cause_o,
  output logic        wdt_reset_o
);
  // ---------------- external windows: behavioral AXI4-Lite memories ----------------
  axil_if #(.ADDR_W(16)) ext ();
  axil_if #(.ADDR_W(26)) ddr ();
  logic [31:0] ext_mem [256];
  logic [31:0] ddr_mem [256];
  logic ext_b, ext_r, ddr_b, ddr_r;
  logic [31:0] ext_q, ddr_q;
  initial for (int i = 0; i < 256; i++) begin
    ext_mem[i] = '0;
    ddr_mem[i] = '0;
  end
  assign ext.awready = ext.awvalid && ext.wvalid && !ext_b;
  assign ext.wready  = ext.awready;
  assign ext.bresp   = 2'b00;
  assign ext.bvalid  = ext_b;
  assign ext.arready = !ext_r;
  assign ext.rdata   = ext_q;
  assign ext.rresp   = 2'b00;
  assign ext.rvalid  = ext_r;
  assign ddr.awready = ddr.awvalid && ddr.wvalid && !ddr_b;
  assign ddr.wready  = ddr.awready;
  assign ddr.bresp   = 2'b00;
  assign ddr.bvalid  = ddr_b;
  assign ddr.arready = !ddr_r;
  assign ddr.rdata   = ddr_q;
  assign ddr.rresp   = 2'b00;
  assign ddr.rvalid  = ddr_r;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ext_b <= 1'b0;
      ext_r <= 1'b0;
      ddr_b <= 1'b0;
      ddr_r <= 1'b0;
    end else begin
      if (ext.awready) begin
        ext_mem[{ext.awaddr[15], ext.awaddr[8:2]}] <= ext.wdata;
        ext_b <= 1'b1;
      end else if (ext.bready) ext_b <= 1'b0;
      if (ext.arvalid && !ext_r) begin
        ext_q <= ext_mem[{ext.araddr[15], ext.araddr[8:2]}];
        ext_r <= 1'b1;
      end else if (ext.rready) ext_r <= 1'b0;
      if (ddr.awready) begin
        ddr_mem[{ddr.awaddr[25], ddr.awaddr[8:2]}] <= ddr.wdata;
        ddr_b <= 1'b1;
      end else if (ddr.bready) ddr_b <= 1'b0;
      if (ddr.arvalid && !ddr_r) begin
        ddr_q <= ddr_mem[{ddr.araddr[25], ddr.araddr[8:2]}];
        ddr_r <= 1'b1;
      end else if (ddr.rready) ddr_r <= 1'b0;
    end
  end

  // ---------------- py_soc ----------------
  logic [1:0] uart_txd, uart_rxd, scl_i, scl_o, scl_t, sda_i, sda_o, sda_t, sclk, mosi, miso;
  logic [3:0] cs_n;
  logic [95:0] gpio_i, gpio_o, gpio_t;
  logic fl_sclk, fl_cs_n, fl_mosi, fl_miso;
  int fl_wip;
  py_soc #(
    .CLK_HZ(100_000_000),
    .UART_BAUD(2_000_000),
    .I2C_HZ(2_000_000),
    .SPI_HZ(10_000_000),
    .FLASH_CLKDIV(3),
    .CLKGEN_EN(1'b0),
    .EXT_EN(1'b1),
    .DDR_EN(1'b1)
  ) u_soc (
    .clk,
    .rst_n,
    .cpu_clk_o(),
    .cpu_rst_n_o(),
    .clk_o(),
    .start_i(1'b0),
    .resume_i(1'b0),
    .resume_pc_i('0),
    .done_o,
    .result_o(),
    .trap_o,
    .trap_cause_o,
    .trap_pc_o(),
    .boot_done_o,
    .boot_err_o,
    .boot_err_code_o(),
    .flash_sclk_o(fl_sclk),
    .flash_cs_n_o(fl_cs_n),
    .flash_mosi_o(fl_mosi),
    .flash_miso_i(fl_miso),
    .uart_txd_o(uart_txd),
    .uart_rxd_i(uart_rxd),
    .i2c_scl_i(scl_i),
    .i2c_scl_o(scl_o),
    .i2c_scl_t(scl_t),
    .i2c_sda_i(sda_i),
    .i2c_sda_o(sda_o),
    .i2c_sda_t(sda_t),
    .spi_sclk_o(sclk),
    .spi_mosi_o(mosi),
    .spi_miso_i(miso),
    .spi_cs_n_o(cs_n),
    .gpio_i,
    .gpio_o,
    .gpio_t,
    .wdt_reset_o,
    .core_rst_n_o(),
    .ext_irq_i,
    .m_ext_axil(ext),
    .m_ddr_axil(ddr)
  );

  // ---------------- board ----------------
  spi_flash_bfm u_flash (
    .sclk(fl_sclk),
    .cs_n(fl_cs_n),
    .mosi(fl_mosi),
    .miso(fl_miso),
    .wip_cycles(fl_wip)
  );
  initial begin : load                             // after the flash model erases itself
    string path;
    #1;
    if ($value$plusargs("FLASH=%s", path)) $readmemh(path, u_flash.mem);
    else $display("py_soc_cocotb_top: no +FLASH=<hex>, the flash is erased");
  end
  assign uart_rxd = {uart_txd[0], uart_txd[1]};
  assign miso     = mosi;
  assign gpio_i   = {gpio2_i, gpio_o[31:0], gpio_o[31:0]};
  tri1 sda0, scl0, sda1, scl1;
  assign sda0 = sda_t[0] ? 1'bz : sda_o[0];
  assign scl0 = scl_t[0] ? 1'bz : scl_o[0];
  assign sda1 = sda_t[1] ? 1'bz : sda_o[1];
  assign scl1 = scl_t[1] ? 1'bz : scl_o[1];
  assign sda_i = {sda1, sda0};
  assign scl_i = {scl1, scl0};
  i2c_bfm #(.ADDR(7'h50)) u_i2c0 (
    .sda(sda0),
    .scl(scl0)
  );
  i2c_bfm #(.ADDR(7'h51)) u_i2c1 (
    .sda(sda1),
    .scl(scl1)
  );
  initial begin : i2c_init                         // after the target's own initialisation
    #1 u_i2c1.mem[0] = 8'h11;
    u_i2c1.mem[1] = 8'h22;
    u_i2c1.mem[2] = 8'h33;
    u_i2c1.mem[3] = 8'h44;
  end
  wire unused_ok = &{1'b0, cs_n, gpio_o[95:32], gpio_t, fl_wip, 1'b0};
endmodule
