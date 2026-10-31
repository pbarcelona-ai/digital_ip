// ***************
// Filename: npu_elt.sv
// Author: FPGA Cores 4 U
// Description: Element-wise engines of the NPU: COPY, UPSAMPLE and ADD
//   (operations 5, 4, 3 of model/npu_model.py; the DDR results equal the
//   model's bit for bit). Version 1.0.0.
//   - COPY: d[4] bytes from d[1] to d[3] (read and write streams run
//     together; the regions must not overlap with d[3] > d[1]).
//   - UPSAMPLE x2 (nearest): C = d[4], H x W = d[5] (H << 16 | W) from d[1];
//     per channel and row: the row read (W <= W_MAX) and written twice as
//     the output rows 2y and 2y + 1 (2W bytes, every byte doubled) at d[3].
//   - ADD: C x H x W bytes of a (d[1]) and b (d[2]) in blocks of BLK bytes:
//     out = clamp((a * MA + b * MB + 2^(S-1)) >> S, -128, 127) at d[3], MA =
//     d[13], MB = d[14] unsigned 32-bit as the model reads them, S = d[15];
//     64-bit arithmetic, exact for 1 <= S <= 62 (S = 0 is an error, as the
//     model's negative shift; S > 62 too: the model's int64 would overflow).
//   start_i (with op_i and the descriptor d_i) starts the operation; done_o
//   pulses at its end, err_o with it for an error (nothing written).
//   Parameters: W_MAX (UPSAMPLE row bytes), BLK (ADD block bytes, a
//   multiple of 32). Clock - clk. Reset - synchronous active low rst_n.
//   Clock-domain crossings - none.
// Date: 2026-10-25
module npu_elt #(
  parameter int W_MAX = 2048,                    // longest UPSAMPLE input row
  parameter int BLK   = 1024                     // ADD block
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  input  logic          start_i,                 // start op_i on d_i
  input  logic [7:0]    op_i,                    // 3 ADD, 4 UPSAMPLE, 5 COPY
  input  logic [511:0]  d_i,                     // the descriptor, word k in [32k +: 32]
  output logic          done_o,                  // one clock: the operation done
  output logic          err_o,                   // with done_o: a bad parameter
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam logic [7:0] OP_ADD = 8'd3, OP_UP = 8'd4, OP_COPY = 8'd5;
  localparam int RBW = W_MAX / 32;               // row buffer words
  localparam int BKW = BLK / 32;                 // block words
  if (W_MAX < 32 || W_MAX % 32 != 0 || BLK < 32 || BLK % 32 != 0) begin : g_bad
    $error("npu_elt: W_MAX and BLK multiples of 32");
  end

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  typedef enum logic [3:0] {S_IDLE, S_CP, S_UP_RD, S_UP_WR, S_AD_RA, S_AD_RB, S_AD_WR, S_DONE} state_e;
  state_e st;
  logic [31:0]  src, src2, dst, nbytes;          // the operation's addresses and size
  logic [15:0]  h, w;
  logic [31:0]  c, ci;                           // channels; the current one
  logic [15:0]  y;                               // the current row
  logic         r2;                              // UPSAMPLE: the second output row
  logic [31:0]  ma, mb;
  logic [5:0]   sh;
  logic [31:0]  off;                             // ADD: the block's offset
  logic         rq_rd, rq_wr;                    // a request presented
  logic [$clog2(RBW > BKW ? RBW : BKW)+1:0] k;   // chunk index (an UPSAMPLE output row: 2 RBW chunks)
  logic         err;
  logic [255:0] rb [RBW];                        // UPSAMPLE row
  logic [255:0] ba [BKW], bb [BKW];              // ADD blocks

  wire [31:0] blk_len = (nbytes - off > 32'(BLK)) ? 32'(BLK) : nbytes - off;
  wire [31:0] up_out = {16'd0, w} << 1;          // bytes of an output row
  // the current write chunk's bytes
  wire [31:0] wr_total = (st == S_UP_WR) ? up_out : blk_len;
  wire [31:0] wr_pos = 32'(k) << 5;
  wire [5:0]  wr_cnt_now = (wr_total - wr_pos >= 32'd32) ? 6'd32 : 6'(wr_total - wr_pos);
  wire        wr_more = wr_pos < wr_total;

  // UPSAMPLE: chunk k of an output row = input bytes 16k .. 16k + 15, each doubled
  logic [255:0] up_data;
  always_comb begin
    logic [255:0] word;
    word = rb[k[$clog2(RBW):1]];
    for (int i = 0; i < 16; i++) begin
      up_data[16*i +: 8] = word[128*k[0] + 8*i +: 8];
      up_data[16*i + 8 +: 8] = word[128*k[0] + 8*i +: 8];
    end
  end
  // ADD: 32 lanes
  logic [255:0] add_data;
  always_comb begin
    logic signed [63:0] t;
    for (int i = 0; i < 32; i++) begin
      t = 64'($signed(ba[k[$clog2(BKW)-1:0]][8*i +: 8])) * $signed({32'd0, ma}) + 64'($signed(bb[k[$clog2(BKW)-1:0]][8*i +: 8])) * $signed({32'd0, mb});
      t = (t + (64'sd1 <<< (sh - 6'd1))) >>> sh;
      add_data[8*i +: 8] = (t > 64'sd127) ? 8'h7F : (t < -64'sd128) ? 8'h80 : t[7:0];
    end
  end

  // DMA requests and streams
  assign dma.rd_req = rq_rd;
  assign dma.wr_req = rq_wr;
  always_comb begin
    dma.rd_addr = src;
    dma.rd_len = nbytes;
    dma.wr_addr = dst;
    dma.wr_len = nbytes;
    dma.rd_rdy = 1'b0;
    dma.wr_valid = 1'b0;
    dma.wr_data = '0;
    dma.wr_cnt = 6'd32;
    unique case (st)
      S_CP: begin                                   // read chunks straight into the write
        dma.rd_rdy = dma.wr_rdy;
        dma.wr_valid = dma.rd_valid;
        dma.wr_data = dma.rd_data;
        dma.wr_cnt = dma.rd_cnt;
      end
      S_UP_RD: begin
        dma.rd_addr = src + 32'(y) * 32'(w);
        dma.rd_len = {16'd0, w};
        dma.rd_rdy = 1'b1;
      end
      S_UP_WR: begin
        dma.wr_addr = dst + ((32'(y) << 1) + 32'(r2)) * up_out;
        dma.wr_len = up_out;
        dma.wr_valid = !rq_wr && wr_more;
        dma.wr_data = up_data;
        dma.wr_cnt = wr_cnt_now;
      end
      S_AD_RA, S_AD_RB: begin
        dma.rd_addr = ((st == S_AD_RA) ? src : src2) + off;
        dma.rd_len = blk_len;
        dma.rd_rdy = 1'b1;
      end
      S_AD_WR: begin
        dma.wr_addr = dst + off;
        dma.wr_len = blk_len;
        dma.wr_valid = !rq_wr && wr_more;
        dma.wr_data = add_data;
        dma.wr_cnt = wr_cnt_now;
      end
      default: ;
    endcase
  end
  wire rd_take = dma.rd_valid && dma.rd_rdy;
  wire wr_take = dma.wr_valid && dma.wr_rdy;

  // buffers: read chunks into the row / block memory
  always_ff @(posedge clk) begin
    if (rd_take && st == S_UP_RD) rb[k[$clog2(RBW)-1:0]] <= dma.rd_data;
    if (rd_take && st == S_AD_RA) ba[k[$clog2(BKW)-1:0]] <= dma.rd_data;
    if (rd_take && st == S_AD_RB) bb[k[$clog2(BKW)-1:0]] <= dma.rd_data;
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      src <= '0;
      src2 <= '0;
      dst <= '0;
      nbytes <= '0;
      h <= '0;
      w <= '0;
      c <= '0;
      ci <= '0;
      y <= '0;
      r2 <= 1'b0;
      ma <= '0;
      mb <= '0;
      sh <= '0;
      off <= '0;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      k <= '0;
      err <= 1'b0;
    end else begin
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      unique case (st)
        S_IDLE: if (start_i) begin
          src <= dw(1);
          src2 <= dw(2);
          dst <= dw(3);
          h <= d_i[32*5+16 +: 16];
          w <= d_i[32*5+0 +: 16];
          c <= dw(4);
          ci <= '0;
          y <= '0;
          r2 <= 1'b0;
          ma <= dw(13);
          mb <= dw(14);
          sh <= 6'(dw(15));
          off <= '0;
          k <= '0;
          err <= 1'b0;
          unique case (op_i)
            OP_COPY: begin
              nbytes <= dw(4);
              if (dw(4) == '0) st <= S_DONE;
              else begin
                rq_rd <= 1'b1;
                rq_wr <= 1'b1;
                st <= S_CP;
              end
            end
            OP_UP: begin
              if (dw(4) == '0 || d_i[32*5+16 +: 16] == '0 || d_i[32*5+0 +: 16] == '0) st <= S_DONE;
              else if (32'(d_i[32*5+0 +: 16]) > 32'(W_MAX)) begin
                err <= 1'b1;
                st <= S_DONE;
              end else begin
                rq_rd <= 1'b1;
                st <= S_UP_RD;
              end
            end
            OP_ADD: begin
              nbytes <= dw(4) * 32'(d_i[32*5+16 +: 16]) * 32'(d_i[32*5+0 +: 16]);
              if (dw(15) == '0 || dw(15) > 32'd62) begin
                err <= 1'b1;
                st <= S_DONE;
              end else if (dw(4) * 32'(d_i[32*5+16 +: 16]) * 32'(d_i[32*5+0 +: 16]) == '0) st <= S_DONE;
              else begin
                rq_rd <= 1'b1;
                st <= S_AD_RA;
              end
            end
            default: begin
              err <= 1'b1;
              st <= S_DONE;
            end
          endcase
        end
        S_CP: if (dma.wr_done) st <= S_DONE;
        S_UP_RD: begin
          if (rd_take) k <= k + 1'b1;
          if (rd_take && dma.rd_last) begin
            k <= '0;
            rq_wr <= 1'b1;
            r2 <= 1'b0;
            st <= S_UP_WR;
          end
        end
        S_UP_WR: begin
          if (wr_take) k <= k + 1'b1;
          if (dma.wr_done) begin
            k <= '0;
            if (!r2) begin
              r2 <= 1'b1;
              rq_wr <= 1'b1;
            end else if (y + 16'd1 < h) begin
              y <= y + 16'd1;
              rq_rd <= 1'b1;
              st <= S_UP_RD;
            end else if (ci + 32'd1 < c) begin       // the next channel: its rows follow in memory
              ci <= ci + 32'd1;
              y <= '0;
              src <= src + 32'(h) * 32'(w);
              dst <= dst + (32'(h) * 32'(w) << 2);
              rq_rd <= 1'b1;
              st <= S_UP_RD;
            end else begin
              st <= S_DONE;
            end
          end
        end
        S_AD_RA: begin
          if (rd_take) k <= k + 1'b1;
          if (rd_take && dma.rd_last) begin
            k <= '0;
            rq_rd <= 1'b1;
            st <= S_AD_RB;
          end
        end
        S_AD_RB: begin
          if (rd_take) k <= k + 1'b1;
          if (rd_take && dma.rd_last) begin
            k <= '0;
            rq_wr <= 1'b1;
            st <= S_AD_WR;
          end
        end
        S_AD_WR: begin
          if (wr_take) k <= k + 1'b1;
          if (dma.wr_done) begin
            k <= '0;
            if (off + blk_len < nbytes) begin
              off <= off + blk_len;
              rq_rd <= 1'b1;
              st <= S_AD_RA;
            end else begin
              st <= S_DONE;
            end
          end
        end
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign done_o = st == S_DONE;
  assign err_o = st == S_DONE && err;
  // not used: the descriptor's other words (the model's operation reads only these)
  wire unused_ok = &{1'b0, d_i, 1'b0};
endmodule
