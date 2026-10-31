// ***************
// Filename: frame_store_if.sv
// Author: FPGA Cores 4 U
// Description: Frame-store interface for double-buffered DDR-backed frame storage
//   with on-chip row cache. Used by vision_system for lens/geometry correction.
//   The store holds two frames (buffers 0 and 1); the writer fills one buffer
//   while the reader reads from the other. At frame boundaries the buffers swap.
//   The row cache keeps recently-read source rows on-chip (the correction mapping
//   is locally smooth, so consecutive output pixels read nearby source rows).
//   Modules take widths as parameters (no $bits on interface members: Icarus);
//   connect a port with the plain instance name (.p(u_if)). A top-level module
//   for synthesis keeps discrete ports (ip/scripts/syn_wrap.py writes the wrapper).
// Date: 2026-10-21
interface frame_store_if #(
  parameter int PIX_W   = 24,             // pixel width (RGB888)
  parameter int ADDR_W  = 20,             // address bits per frame (MAX_W * MAX_H)
  parameter int CACHE_LINES = 8,          // number of cached rows
  parameter int CACHE_LINE_W = 11         // log2 of pixels per cached row (e.g., 11 = 2048 pixels)
) ();
  // Write port (used by axis_in_ctrl equivalent): sequential raster writes
  logic                     wr_en;        // write strobe (one pixel per clock)
  logic [ADDR_W-1:0]        wr_addr;      // pixel address within the frame
  logic [PIX_W-1:0]         wr_data;      // pixel data
  logic                     wr_buf_sel;   // buffer being written (0 or 1)
  logic                     wr_ready;     // store can accept write
  logic                     wr_frame_done;// frame write complete (pulsed)

  // Read port (used by axis_out_ctrl equivalent): four-address reads for interpolation
  logic                     rd_en;        // read request (four addresses)
  logic [ADDR_W-1:0]        rd_addr0;     // read address 0
  logic [ADDR_W-1:0]        rd_addr1;     // read address 1
  logic [ADDR_W-1:0]        rd_addr2;     // read address 2
  logic [ADDR_W-1:0]        rd_addr3;     // read address 3
  logic                     rd_buf_sel;   // buffer being read (0 or 1)
  logic                     rd_ready;     // store can accept read request
  logic                     rd_valid;     // read data valid (one cycle after rd_en accepted)
  logic [PIX_W-1:0]         rd_data0;     // pixel at rd_addr0
  logic [PIX_W-1:0]         rd_data1;     // pixel at rd_addr1
  logic [PIX_W-1:0]         rd_data2;     // pixel at rd_addr2
  logic [PIX_W-1:0]         rd_data3;     // pixel at rd_addr3

  // Buffer management
  logic                     swap_buf;     // pulse: swap write/read buffers at frame boundary
  logic                     buf_swapped;  // buffer swap acknowledged

  // Cache control (for row cache)
  logic                     cache_flush;  // flush cache (at frame start or buffer swap)
  logic                     cache_flushed;// cache flush acknowledged

  // Status
  logic                     store_idle;   // no pending writes or reads
  logic [1:0]               wr_fill;      // write buffer fill level (0: empty, 1: partial, 2: full, 3: overflow)
  logic [1:0]               rd_fill;      // read buffer fill level

  // PIX_W: pixel width, ADDR_W: address bits per frame
  // CACHE_LINES: number of cached rows, CACHE_LINE_W: log2 pixels per cached row

  modport writer (
    output wr_en, wr_addr, wr_data, wr_buf_sel, wr_frame_done, swap_buf, cache_flush,
    input  wr_ready, buf_swapped, cache_flushed, store_idle, wr_fill, rd_fill
  );
  modport reader (
    output rd_en, rd_addr0, rd_addr1, rd_addr2, rd_addr3, rd_buf_sel,
    input  rd_ready, rd_valid, rd_data0, rd_data1, rd_data2, rd_data3, store_idle, wr_fill, rd_fill
  );
  modport store (
    input  wr_en, wr_addr, wr_data, wr_buf_sel, wr_frame_done, swap_buf, cache_flush,
    output wr_ready, buf_swapped, cache_flushed, store_idle, wr_fill, rd_fill,
    input  rd_en, rd_addr0, rd_addr1, rd_addr2, rd_addr3, rd_buf_sel,
    output rd_ready, rd_valid, rd_data0, rd_data1, rd_data2, rd_data3
  );
  modport monitor (
    input  wr_en, wr_addr, wr_data, wr_buf_sel, wr_ready, wr_frame_done, swap_buf, cache_flush,
    input  buf_swapped, cache_flushed, store_idle, wr_fill, rd_fill,
    input  rd_en, rd_addr0, rd_addr1, rd_addr2, rd_addr3, rd_buf_sel,
    input  rd_ready, rd_valid, rd_data0, rd_data1, rd_data2, rd_data3
  );
endinterface