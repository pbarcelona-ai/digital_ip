// ***************
// Filename: py_stream_port_regs_pkg.sv
// Author: FPGA Cores 4 U
// Description: Register offsets of py_stream_port (byte offsets in its
//   window) and bit fields (<REG>_<FIELD>_LSB / _MASK), for firmware ("from
//   py_stream_port_regs_pkg import *" in pyc.py) and testbenches. Generated
//   by ip/scripts/regmap_gen.py from py_stream_port_regs.json.
// Date: 2026-10-20
package py_stream_port_regs_pkg;
  localparam int PY_STREAM_PORT_ID = 'h0;
  localparam int PY_STREAM_PORT_VERSION = 'h4;
  localparam int PY_STREAM_PORT_DATE = 'h8;
  localparam int PY_STREAM_PORT_TXDATA = 'h10;
  localparam int PY_STREAM_PORT_TXDATA_DATA_LSB = 0;
  localparam int PY_STREAM_PORT_TXDATA_DATA_MASK = 'hFFFFFF;
  localparam int PY_STREAM_PORT_TXDATA_LAST_LSB = 24;
  localparam int PY_STREAM_PORT_TXDATA_LAST_MASK = 'h1000000;
  localparam int PY_STREAM_PORT_RXDATA = 'h14;
  localparam int PY_STREAM_PORT_RXDATA_DATA_LSB = 0;
  localparam int PY_STREAM_PORT_RXDATA_DATA_MASK = 'hFFFFFF;
  localparam int PY_STREAM_PORT_RXDATA_LAST_LSB = 24;
  localparam int PY_STREAM_PORT_RXDATA_LAST_MASK = 'h1000000;
  localparam int PY_STREAM_PORT_RXDATA_VALID_LSB = 31;
  localparam int PY_STREAM_PORT_RXDATA_VALID_MASK = 'h80000000;
  localparam int PY_STREAM_PORT_STATUS = 'h18;
  localparam int PY_STREAM_PORT_STATUS_RX_VALID_LSB = 0;
  localparam int PY_STREAM_PORT_STATUS_RX_VALID_MASK = 'h1;
  localparam int PY_STREAM_PORT_STATUS_TX_READY_LSB = 1;
  localparam int PY_STREAM_PORT_STATUS_TX_READY_MASK = 'h2;
  localparam int PY_STREAM_PORT_STATUS_TX_OVF_LSB = 2;
  localparam int PY_STREAM_PORT_STATUS_TX_OVF_MASK = 'h4;
  localparam int PY_STREAM_PORT_STATUS_TX_EMPTY_LSB = 3;
  localparam int PY_STREAM_PORT_STATUS_TX_EMPTY_MASK = 'h8;
  localparam int PY_STREAM_PORT_STATUS_RX_LEVEL_LSB = 8;
  localparam int PY_STREAM_PORT_STATUS_RX_LEVEL_MASK = 'hFFF00;
  localparam int PY_STREAM_PORT_STATUS_TX_LEVEL_LSB = 20;
  localparam int PY_STREAM_PORT_STATUS_TX_LEVEL_MASK = 'hFFF00000;
  localparam int PY_STREAM_PORT_IRQ_EN = 'h1C;
  localparam int PY_STREAM_PORT_IRQ_EN_RX_VALID_LSB = 0;
  localparam int PY_STREAM_PORT_IRQ_EN_RX_VALID_MASK = 'h1;
  localparam int PY_STREAM_PORT_IRQ_EN_TX_READY_LSB = 1;
  localparam int PY_STREAM_PORT_IRQ_EN_TX_READY_MASK = 'h2;
  localparam int PY_STREAM_PORT_IRQ_EN_TX_EMPTY_LSB = 2;
  localparam int PY_STREAM_PORT_IRQ_EN_TX_EMPTY_MASK = 'h4;
endpackage
