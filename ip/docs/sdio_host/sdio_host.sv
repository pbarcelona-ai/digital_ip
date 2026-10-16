// ***************
// Filename: sdio_host.sv
// Author: FPGA Cores 4 U
// Description: SD / SDIO host controller (single-block transfers, 1-bit or
//   4-bit data bus, SD mode). Version 1.0.0. AXI4-Lite registers issue one
//   command at a time - 0x00 CMD (write starts it): index[5:0],
//   response[7:6] (0 none, 1 short 48 bit, 2 long 136 bit), data
//   direction[9:8] (0 none, 1 read block, 2 write block), no_crc_check[10]
//   (for R3/R7-style responses without valid CRC7); 0x04 ARG; 0x08..0x14
//   RESP0..RESP3 (short response argument in RESP0, long response 127..0
//   in RESP3..RESP0); 0x18 STATUS (bit0 busy, bit1 cmd_done, bit2
//   dat_done, bit3 cmd_timeout, bit4 cmd_crc_err, bit5 dat_crc_err, bit6
//   dat_timeout, bit7 buf_err; write 1 to clear bits 1-7); 0x1C CTRL
//   (half_period[15:0] in system clocks, minimum 1, bus4[16], clk_en[17]);
//   0x20 BLKSIZE (bytes, 1..BUF_BYTES); 0x24 TIMEOUT (SD clocks for
//   data/busy timeout); 0x28 IRQ_EN (bit n enables STATUS bit n+1 for
//   irq_o); 0x2C IP_VERSION. Data - a block buffer of BUF_BYTES bytes
//   decouples the free-running SD clock from AXI-Stream: for a write, fill
//   the buffer through s_axis (BLKSIZE bytes, only accepted while idle)
//   and then issue the write command; a read block is verified (CRC16 per
//   data line) and only then streamed out on m_axis (tlast on the final
//   byte), a block with a CRC error is discarded. The command engine
//   appends CRC7, checks the CRC7 of short responses, waits up to 80 SD
//   clocks for a response, and for writes handles the CRC status token and
//   the busy signal. SD signals - sd_clk_o (half period = CTRL.half_period
//   system clocks), cmd_o/cmd_oe_o/cmd_i and dat_o/dat_oe_o/dat_i[3:0] are
//   separate outputs and inputs (connect to tri-state buffers at the top
//   level, external pull-ups on CMD/DAT); outputs change on the falling
//   edge of sd_clk_o, inputs are double-registered and sampled on rising
//   edges. Clock - aclk; SD clock runs only while CTRL.clk_en=1 and must
//   be running for a command to progress (initialisation at 400 kHz needs
//   a half period of 125 at 100 MHz). Not supported - multi-block
//   transfers, SPI mode, UHS-I / 1.8 V, DMA. Reset - synchronous aresetn,
//   sd_clk low, all lines released. Latency - about 2*half_period system
//   clocks per SD clock; a 512 byte block takes about 1100 SD clocks in
//   4-bit mode and 4200 in 1-bit mode. Errors - cmd_timeout, cmd_crc_err,
//   dat_crc_err (also for a bad end bit or write CRC status), dat_timeout,
//   buf_err (bad BLKSIZE, write without a full buffer, or a command while
//   busy).
// Date: 2026-09-29

module sdio_host #(
  parameter int BUF_BYTES = 512
) (
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
  // AXI-Stream block data
  input  logic [7:0]  s_axis_tdata,
  input  logic        s_axis_tvalid,
  output logic        s_axis_tready,
  output logic [7:0]  m_axis_tdata,
  output logic        m_axis_tvalid,
  input  logic        m_axis_tready,
  output logic        m_axis_tlast,
  // SD pins
  output logic        sd_clk_o,
  output logic        cmd_o,
  output logic        cmd_oe_o,
  input  logic        cmd_i,
  output logic [3:0]  dat_o,
  output logic [3:0]  dat_oe_o,
  input  logic [3:0]  dat_i,
  output logic        irq_o
);
