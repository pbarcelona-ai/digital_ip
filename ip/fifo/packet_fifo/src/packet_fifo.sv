// ***************
// Filename: packet_fifo.sv
// Author: Paul Barcelona
// Description: Packet-preserving FIFO (store and forward). Version 1.0.0.
//   Words are written with s_last_i marking the final word of a packet. A
//   packet becomes visible on the master side only when its last word has
//   been stored, so downstream logic never sees a partial packet. If the
//   FIFO fills in the middle of a packet the whole packet is discarded
//   (the write pointer is rolled back at the packet end) and drop_o
//   pulses; s_ready_o stays high in that case so the source is never
//   blocked mid-packet. A packet larger than the FIFO is therefore always
//   dropped. Optional DROP_ON_BAD: s_bad_i on the last word drops the
//   packet (e.g. CRC error). Clock - clk. Reset - synchronous active low.
//   Latency - a packet appears 2 clocks after its last word; words stream
//   1 per clock afterwards. Storage - block RAM. Errors - drop_o (pulse),
//   pkt_count_o; DEPTH must be a power of two >= 4.
// Date: 2026-09-29
module packet_fifo #(
  parameter int WIDTH        = 32,
  parameter int DEPTH        = 512,
  parameter bit DROP_ON_BAD  = 1'b1
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic [WIDTH-1:0]         s_data_i,
  input  logic                     s_valid_i,
  output logic                     s_ready_o,
  input  logic                     s_last_i,
  input  logic                     s_bad_i,        // with s_last_i: drop this packet
  output logic [WIDTH-1:0]         m_data_o,
  output logic                     m_valid_o,
  input  logic                     m_ready_i,
  output logic                     m_last_o,
  output logic                     drop_o,         // one clock per dropped packet
  output logic [$clog2(DEPTH):0]   pkt_count_o     // complete packets stored
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int AW = $clog2(DEPTH);
  if (DEPTH < 4 || (DEPTH & (DEPTH - 1)) != 0) begin : g_bad $error("packet_fifo: DEPTH must be a power of two >= 4"); end
  logic [WIDTH:0] mem [0:DEPTH-1];                 // {last, data}
  logic [AW:0] wptr, cptr, rptr;                   // write, commit, read pointers
  logic        discard;                            // dropping the current packet
  wire         space = ((wptr - rptr) != DEPTH);
  assign s_ready_o = 1'b1;
  wire do_wr = s_valid_i & space & ~discard;

  always_ff @(posedge clk) if (do_wr) mem[wptr[AW-1:0]] <= {s_last_i, s_data_i};

  // Packet count is incremented in the write process and decremented on read of a last word
  logic [AW:0] pcnt; logic pop_pkt;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wptr <= '0; cptr <= '0; discard <= 1'b0; drop_o <= 1'b0; pcnt <= '0;
    end else begin
      drop_o <= 1'b0;
      if (s_valid_i) begin
        if (!space || discard) begin
          // out of space: enter / stay in discard until the packet ends
          if (s_last_i) begin wptr <= cptr; discard <= 1'b0; drop_o <= 1'b1; end
          else discard <= 1'b1;
        end else begin
          wptr <= wptr + 1'b1;
          if (s_last_i) begin
            if (DROP_ON_BAD && s_bad_i) begin wptr <= cptr; drop_o <= 1'b1; end
            else begin cptr <= wptr + 1'b1; end
          end
        end
      end
      pcnt <= pcnt + ((s_valid_i & s_last_i & space & ~discard & ~(DROP_ON_BAD & s_bad_i)) ? 1'b1 : 1'b0)
                   - (pop_pkt ? 1'b1 : 1'b0);
    end
  end
  assign pkt_count_o = pcnt;

  // Read side: prefetch from RAM into an output register while committed data exists
  logic [WIDTH:0] q; logic q_v;
  wire  out_take = q_v & m_ready_i;
  wire  rd_en    = (rptr != cptr) & (~q_v | out_take);
  always_ff @(posedge clk) begin
    if (!rst_n) begin rptr <= '0; q_v <= 1'b0; q <= '0; end
    else begin
      if (rd_en) begin q <= mem[rptr[AW-1:0]]; rptr <= rptr + 1'b1; end
      q_v <= rd_en | (q_v & ~out_take);
    end
  end
  assign pop_pkt   = out_take & q[WIDTH];
  assign m_valid_o = q_v;
  assign m_data_o  = q[WIDTH-1:0];
  assign m_last_o  = q[WIDTH];
endmodule
