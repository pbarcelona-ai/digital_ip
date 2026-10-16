// ***************
// Filename: spi_if.sv
// Author: FPGA Cores 4 U
// Description: SPI bus pins (Motorola SPI: SCLK, MOSI, MISO, SS active low) between a controller
//   (spi_master, spi_flash_ctrl) and its peripherals. Modules take widths as parameters (no $bits
//   on interface members: Icarus); connect a port with the plain instance name (.p(u_if)). A top-
//   level module for synthesis keeps discrete ports (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-16
interface spi_if #(
  parameter int NUM_CS = 1
) ();
  logic sclk;                           // serial clock
  logic mosi;                           // controller out
  logic miso;                           // controller in
  logic [NUM_CS-1:0] cs_n;              // chip selects, active low
  // NUM_CS: chip selects

  modport master (output sclk, mosi, cs_n, input miso);
  modport slave (output miso, input sclk, mosi, cs_n);
  modport monitor (input sclk, mosi, miso, cs_n);
endinterface
