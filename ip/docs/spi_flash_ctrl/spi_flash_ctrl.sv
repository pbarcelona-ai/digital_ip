// ***************
// Filename: spi_flash_ctrl.sv
// Author: FPGA Cores 4 U
// Description: SPI NOR flash controller (single-bit SPI mode 0, 3-byte
//   addressing, e.g. W25Qxx / S25FL / MX25). Version 1.0.0. AXI4-Lite
//   registers issue generic commands - write CMD (0x00) with opcode[7:0],
//   addr_en[8], dummy bytes[15:12], read_data[16], write_data[17] after
//   setting ADDR (0x04, 24 bit) and LEN (0x08, data bytes 0..65535); the
//   controller then drives cs_n, sends opcode, address and dummy bytes and
//   moves LEN data bytes: bytes read from the flash leave on the AXI-
//   Stream master port (m_axis) and bytes to write are taken from the AXI-
//   Stream slave port (s_axis), each waiting for the stream handshake with
//   sclk stopped between bytes (so the flash never sees a gap it cannot
//   handle, and no byte is lost). Any flash command is expressible: 9F
//   read ID, 03/0B read, 06 write enable, 02 page program, 20/D8/C7 erase,
//   05 read status (poll STATUS-of-flash yourself by issuing 05 with
//   LEN=1). Registers - 0x00 CMD (write starts, reads back last), 0x04
//   ADDR, 0x08 LEN, 0x0C CLKDIV (sclk half period in clocks, min 3, reset
//   4, so 12.5 MHz at 100 MHz), 0x10 STATUS (bit0 busy, bit1 done sticky,
//   bit2 cmd_err sticky; write 1 to clear bits 1 and 2), 0x14 IRQ_EN
//   (bit0), 0x18 IP_VERSION. A CMD written while busy is ignored and sets
//   cmd_err. irq_o = done & IRQ_EN. Clock - aclk; miso is asynchronous and
//   double-registered, which is why the half period is at least 3 clocks.
//   Reset - synchronous aresetn, cs_n high, sclk low. Timing - cs_n is
//   asserted one half period before the first sclk edge, held one half
//   period after the last, and kept high for two half periods between
//   commands. Latency - command starts 2 clocks after the CMD write; data
//   throughput is 8 bit times per byte plus stream wait. The flash write-
//   in-progress state is the flash's own business: poll it with command
//   05. Errors - cmd_err (command while busy); a stalled stream simply
//   pauses the transfer.
// Date: 2026-09-29

module spi_flash_ctrl (
  input  logic        aclk,
  input  logic        aresetn,
  // AXI4-Lite slave
  input  logic [7:0]  s_axil_awaddr,
  input  logic        s_axil_awvalid,
  output logic        s_axil_awready,
  input  logic [31:0] s_axil_wdata,
  input  logic [3:0]  s_axil_wstrb,
  input  logic        s_axil_wvalid,
  output logic        s_axil_wready,
  output logic [1:0]  s_axil_bresp,
  output logic        s_axil_bvalid,
  input  logic        s_axil_bready,
  input  logic [7:0]  s_axil_araddr,
  input  logic        s_axil_arvalid,
  output logic        s_axil_arready,
  output logic [31:0] s_axil_rdata,
  output logic [1:0]  s_axil_rresp,
  output logic        s_axil_rvalid,
  input  logic        s_axil_rready,
  // AXI-Stream: bytes to write to the flash
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  // AXI-Stream: bytes read from the flash
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // SPI pins
  output logic        sclk_o,
  output logic        cs_n_o,
  output logic        mosi_o,
  input  logic        miso_i,
  output logic        irq_o
);
