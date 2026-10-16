// ***************
// Filename: axi_stream_width_converter.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream data width converter. Version 1.0.0. Converts
//   between IN_BYTES and OUT_BYTES wide streams; one width must be an
//   integer multiple of the other (or equal, giving a register slice).
//   Little-endian byte order - byte 0 of the wide word is the first byte
//   on the narrow side. tkeep and tlast are honoured. Downsizing splits
//   each input beat into OUT_BYTES chunks, skipping trailing all-zero-keep
//   chunks and setting tlast on the last valid chunk of a packet. Upsizing
//   packs beats into one output word, flushing early on tlast (tkeep marks
//   the valid bytes). tuser is carried on the tlast beat only. Clock -
//   aclk. Reset - synchronous aresetn, idle. Throughput - full rate on the
//   narrow side. Latency - 1 clock (downsize/equal) or IN/OUT ratio clocks
//   (upsize). Errors - unsupported ratios rejected at elaboration; tkeep
//   patterns must be contiguous from byte 0 (a gap raises keep_err_o for
//   one clock and the beat is passed as given).
// Date: 2026-09-29

module axi_stream_width_converter #(
  parameter int IN_BYTES  = 4,
  parameter int OUT_BYTES = 1,
  parameter int USER_W    = 1
) (
  input  logic                    aclk,
  input  logic                    aresetn,
  input  logic [IN_BYTES*8-1:0]   s_axis_tdata,
  input  logic [IN_BYTES-1:0]     s_axis_tkeep,
  input  logic                    s_axis_tlast,
  input  logic [USER_W-1:0]       s_axis_tuser,
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  output logic [OUT_BYTES*8-1:0]  m_axis_tdata,
  output logic [OUT_BYTES-1:0]    m_axis_tkeep,
  output logic                    m_axis_tlast,
  output logic [USER_W-1:0]       m_axis_tuser,
  output logic                    m_axis_tvalid,
  input  logic                    m_axis_tready,
  output logic                    keep_err_o
);
