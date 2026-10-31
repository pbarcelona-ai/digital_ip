// ***************
// Filename: npu_dma_if.sv
// Author: FPGA Cores 4 U
// Description: The request / stream interface of npu_dma, between an NPU
//   engine (modport cli) and the DMA (modport srv; npu.sv selects the
//   active engine's). Read: rd_req with rd_ready (rd_addr, rd_len bytes),
//   then 32-byte chunks aligned to the first byte (rd_valid / rd_rdy,
//   rd_cnt bytes valid, rd_last). Write: wr_req with wr_ready (wr_addr,
//   wr_len), chunks in (wr_valid / wr_rdy, wr_cnt: 32 but the last),
//   wr_done one clock once every byte is in memory. See npu_dma.sv.
// Date: 2026-10-25
interface npu_dma_if ();
  logic         rd_req;                          // start a read (taken with rd_ready)
  logic         rd_ready;                        // no read active
  logic [31:0]  rd_addr;                         // first byte
  logic [31:0]  rd_len;                          // bytes (>= 1)
  logic         rd_valid;                        // a chunk
  logic         rd_rdy;                          // the chunk taken
  logic [255:0] rd_data;                         // byte 0 first
  logic [5:0]   rd_cnt;                          // bytes in the chunk
  logic         rd_last;                         // the last chunk
  logic         wr_req;                          // start a write (taken with wr_ready)
  logic         wr_ready;                        // no write active
  logic [31:0]  wr_addr;                         // first byte
  logic [31:0]  wr_len;                          // bytes (>= 1)
  logic         wr_valid;                        // a chunk
  logic         wr_rdy;                          // the chunk taken
  logic [255:0] wr_data;                         // byte 0 first
  logic [5:0]   wr_cnt;                          // bytes in the chunk
  logic         wr_done;                         // one clock: the write is in memory

  modport cli (output rd_req, rd_addr, rd_len, rd_rdy, wr_req, wr_addr, wr_len, wr_valid, wr_data, wr_cnt,
               input rd_ready, rd_valid, rd_data, rd_cnt, rd_last, wr_ready, wr_rdy, wr_done);
  modport srv (input rd_req, rd_addr, rd_len, rd_rdy, wr_req, wr_addr, wr_len, wr_valid, wr_data, wr_cnt,
               output rd_ready, rd_valid, rd_data, rd_cnt, rd_last, wr_ready, wr_rdy, wr_done);
endinterface
