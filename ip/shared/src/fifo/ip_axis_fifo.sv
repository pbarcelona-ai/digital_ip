// ***************
// Filename: ip_axis_fifo.sv
// Author: FPGA Cores 4 U
// Description: Single clock AXI-Stream FIFO with tlast and tuser sideband
//   bits. Storage is a synchronous-read memory that maps to block RAM for
//   deep configurations, followed by a two register output pipeline
//   (memory data register and output register) so every path is short at
//   100 MHz. Reports the total number of stored entries on level_o.
//   Version 1.0.0. Clock - single clock clk. Reset - synchronous active
//   low, empty. Latency - 2 clocks from tvalid to output (registered
//   read). Timing - registered outputs. Errors - a write while full is
//   refused by tready=0; illegal parameters stop elaboration.
// Date: 2026-10-20
module ip_axis_fifo #(
  parameter int DATA_W = 8,     // tdata width
  parameter int DEPTH  = 512    // memory depth, must be a power of two >= 2
) (
  input  logic                     clk,
  input  logic                     rst_n,
  // Slave (write) port
  // s: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.slave s,
  // Master (read) port
  // m: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = DATA_W
  axis_if.master m,
  // Number of words held in the FIFO
  output logic [$clog2(DEPTH)+1:0] level_o
);
  assign m.tkeep = '1;      // not used by this block
  /* verilator lint_off UNUSEDPARAM */             // version identification (library convention), not logic
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  /* verilator lint_on UNUSEDPARAM */
  if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0) begin : g_chk_d $error("%m: DEPTH must be a power of two >= 2"); end
  if (DATA_W < 1) begin : g_chk_w $error("%m: DATA_W must be >= 1"); end

  localparam int AW = $clog2(DEPTH);
  localparam int W  = DATA_W + 2;            // data + tlast + tuser

  logic [W-1:0] mem [0:DEPTH-1];             // inferred RAM
  logic [AW:0]  wr_ptr, rd_ptr;              // pointers with wrap bit
  logic [W-1:0] mem_q;                       // memory read register
  logic         mem_q_vld;
  logic [W-1:0] o_q;                         // output register
  logic         o_vld;

  wire empty = (wr_ptr == rd_ptr);
  wire full  = (wr_ptr[AW] != rd_ptr[AW]) && (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
  wire wr_en = s.tvalid & ~full;
  // Move memory register to output register when the latter is free
  wire move  = mem_q_vld & (~o_vld | m.tready);
  // Issue a memory read when the memory register is free or being freed
  wire rd_en = ~empty & (~mem_q_vld | move);

  assign s.tready = ~full;
  assign m.tvalid = o_vld;
  assign {m.tuser, m.tlast, m.tdata} = o_q;
  wire [AW+1:0] lvl_mem = {1'b0, wr_ptr - rd_ptr};   // entries in RAM
  assign level_o = lvl_mem + {{(AW+1){1'b0}}, mem_q_vld} + {{(AW+1){1'b0}}, o_vld};

  // Memory write port
  always_ff @(posedge clk) begin
    if (wr_en) mem[wr_ptr[AW-1:0]] <= {s.tuser, s.tlast, s.tdata};
  end

  // Memory read port (synchronous, enable gated for BRAM mapping)
  always_ff @(posedge clk) begin
    if (rd_en) mem_q <= mem[rd_ptr[AW-1:0]];
  end

  // Pointers and valid flags
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wr_ptr    <= '0;
      rd_ptr    <= '0;
      mem_q_vld <= 1'b0;
      o_vld     <= 1'b0;
      o_q       <= '0;
    end else begin
      if (wr_en) wr_ptr <= wr_ptr + 1'b1;
      if (rd_en) rd_ptr <= rd_ptr + 1'b1;
      mem_q_vld <= rd_en | (mem_q_vld & ~move);
      if (move) begin
        o_q   <= mem_q;
        o_vld <= 1'b1;
      end else if (o_vld & m.tready) begin
        o_vld <= 1'b0;
      end
    end
  end
endmodule
