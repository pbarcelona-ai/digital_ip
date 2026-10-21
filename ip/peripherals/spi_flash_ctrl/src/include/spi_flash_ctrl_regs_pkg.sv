// ***************
// Filename: spi_flash_ctrl_regs_pkg.sv
// Author: FPGA Cores 4 U
// Description: Register offsets of spi_flash_ctrl (byte offsets in its
//   window) and bit fields (<REG>_<FIELD>_LSB / _MASK), for firmware ("from
//   spi_flash_ctrl_regs_pkg import *" in pyc.py) and testbenches. Generated
//   by ip/scripts/regmap_gen.py from spi_flash_ctrl_regs.json.
// Date: 2026-10-20
package spi_flash_ctrl_regs_pkg;
  localparam int SPI_FLASH_CTRL_ID = 'h0;
  localparam int SPI_FLASH_CTRL_VERSION = 'h4;
  localparam int SPI_FLASH_CTRL_DATE = 'h8;
  localparam int SPI_FLASH_CTRL_CMD = 'h10;
  localparam int SPI_FLASH_CTRL_CMD_OPCODE_LSB = 0;
  localparam int SPI_FLASH_CTRL_CMD_OPCODE_MASK = 'hFF;
  localparam int SPI_FLASH_CTRL_CMD_ADDR_EN_LSB = 8;
  localparam int SPI_FLASH_CTRL_CMD_ADDR_EN_MASK = 'h100;
  localparam int SPI_FLASH_CTRL_CMD_DUMMY_LSB = 12;
  localparam int SPI_FLASH_CTRL_CMD_DUMMY_MASK = 'hF000;
  localparam int SPI_FLASH_CTRL_CMD_READ_DATA_LSB = 16;
  localparam int SPI_FLASH_CTRL_CMD_READ_DATA_MASK = 'h10000;
  localparam int SPI_FLASH_CTRL_CMD_WRITE_DATA_LSB = 17;
  localparam int SPI_FLASH_CTRL_CMD_WRITE_DATA_MASK = 'h20000;
  localparam int SPI_FLASH_CTRL_ADDR = 'h14;
  localparam int SPI_FLASH_CTRL_LEN = 'h18;
  localparam int SPI_FLASH_CTRL_CLKDIV = 'h1C;
  localparam int SPI_FLASH_CTRL_STATUS = 'h20;
  localparam int SPI_FLASH_CTRL_STATUS_BUSY_LSB = 0;
  localparam int SPI_FLASH_CTRL_STATUS_BUSY_MASK = 'h1;
  localparam int SPI_FLASH_CTRL_STATUS_DONE_LSB = 1;
  localparam int SPI_FLASH_CTRL_STATUS_DONE_MASK = 'h2;
  localparam int SPI_FLASH_CTRL_STATUS_CMD_ERR_LSB = 2;
  localparam int SPI_FLASH_CTRL_STATUS_CMD_ERR_MASK = 'h4;
  localparam int SPI_FLASH_CTRL_IRQ_EN = 'h24;
endpackage
