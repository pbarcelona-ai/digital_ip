// ***************
// Filename: npu_decode.sv
// Author: FPGA Cores 4 U
// Description: DECODE engine of the NPU (operation 7 of model/npu_model.py;
//   the DDR result and the candidate count equal the model's bit for bit).
//   Version 1.0.2.
//   One detection scale: box tensor 4 REG x H x W (d[1]) and class tensor
//   NC x H x W (d[2]); REG = d[4][31:16], NC = d[4][15:0], H x W = d[5],
//   stride = d[8][7:0], level = d[8][15:8]; the exp LUT (256 x u16, Q15) at
//   d[12], the sigmoid LUT (256 x u8) at d[12] + 512; THRESH = d[13] (bit 7:
//   d[13] - 256). Per anchor (row by row, x in order): the best class logit
//   (the first maximum); an anchor reaching THRESH gives, while fewer than
//   CAND_MAX candidates exist in the run, a candidate at d[3] + 16 ncand:
//   per side the distribution's maximum, weights e = expLUT[max - v],
//   distance ((sum e r) << 4) / sum e (0 if the sum is 0, as numpy), the
//   corners from the anchor centre ((2 x + 1) << 3, Q4) mapped to frame
//   pixels: ((v stride) >> 4) - offset, then (p INV + 2^15) >> 16 clamped to
//   the frame; words: x0 | x1 << 16, y0 | y1 << 16, class | score << 8 |
//   level << 16 (score = sigLUT[best + 128]), 0. The letterbox (offset,
//   INV) of bank 1 or, with descriptor flag BANK2, bank 2; the frame size.
//   cand_o pulses per candidate written (npu.sv counts them: ncand_i).
//   Per row: the NC class rows streamed (32 lanes per clock), the 4 REG box
//   rows buffered, then each kept anchor (REG clocks per side for the
//   maximum, REG for the sums, a 28-step divider) and its record written.
//   Errors (err_o with done_o): REG or NC 0 (the model's empty maximum),
//   REG > REG_MAX, W > W_MAX.
//   Parameters: W_MAX (anchors per row, multiple of 32), REG_MAX, CAND_MAX.
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_decode #(
  parameter int W_MAX    = 256,                  // anchors per row
  parameter int REG_MAX  = 16,                   // distribution bins
  parameter int CAND_MAX = 2048                  // candidates per run
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  input  logic          start_i,                 // start on d_i
  input  logic [511:0]  d_i,                     // the descriptor, word k in [32k +: 32]
  input  logic [271:0]  geom_i,                  // the run's frame / letterbox registers (as npu_input)
  input  logic [63:0]   inv_i,                   // LB_INV, LB2_INV
  input  logic [11:0]   ncand_i,                 // candidates in the run so far
  output logic          cand_o,                  // one clock: a candidate written
  output logic          done_o,                  // one clock: the operation done
  output logic          err_o,                   // with done_o: a bad parameter
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam int NB = 4 * REG_MAX;               // box rows
  localparam int XB = $clog2(W_MAX);
  if (W_MAX % 32 != 0 || REG_MAX < 1) begin : g_bad
    $error("npu_decode: W_MAX a multiple of 32");
  end

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  typedef enum logic [3:0] {S_IDLE, S_LUT, S_ROW, S_CLS, S_BOX, S_ANC, S_MX, S_SUM, S_DIV, S_NEXT, S_REC, S_WR,
                            S_DONE} state_e;
  state_e st;
  logic [31:0]  boxa, clsa, dst, lut_a, inv;
  logic [15:0]  reg_n, nc, h, w, ox, oy, fw, fh;
  logic [7:0]   stride, level;
  logic signed [33:0] thresh;
  logic [15:0]  y, x, c;                         // row, anchor, class / box row
  logic [1:0]   side;
  logic [4:0]   r;                               // bin
  logic [9:0]   kc;                              // chunk index
  logic         rq_rd, rq_wr, err, full;
  logic [15:0]  explut [256];
  logic [7:0]   siglut [256];
  logic signed [7:0] best [W_MAX];
  logic [15:0]  bcls [W_MAX];
  // the row's box values: box row b, anchor a in lane a mod 32 at entry {b, a / 32} (npu_lane_mem)
  localparam int BBA = $clog2(NB) + $clog2(W_MAX / 32);
  logic [31:0]          bb_we;
  logic [31:0][BBA-1:0] bb_wa, bb_ra;
  logic [31:0][7:0]     bb_wd, bb_q;
  logic signed [7:0] mx;
  logic [27:0]  num;                             // sum e r (then shifted by 4)
  logic [20:0]  den;                             // sum e
  logic [27:0]  quo;
  logic [4:0]   dstep;
  wire  [27:0]  qbit = 28'd1 << (3'd7 - dstep[2:0]);   // the quotient bit tried this step
  logic [7:0]   sd [4];                        // l, t, r, b (Q4)
  logic [127:0] rec;

  // the bank's letterbox
  wire        bank2 = d_i[32*0+8];
  wire [95:0] gb = bank2 ? geom_i[271:176] : geom_i[175:80];

  // DMA
  assign dma.rd_req = rq_rd;
  assign dma.wr_req = rq_wr;
  always_comb begin
    dma.rd_addr = lut_a;
    dma.rd_len = 32'd768;
    dma.rd_rdy = 1'b0;
    unique case (st)
      S_LUT: dma.rd_rdy = 1'b1;
      S_CLS: begin
        dma.rd_addr = clsa + (32'(c) * 32'(h) + 32'(y)) * 32'(w);
        dma.rd_len = 32'(w);
        dma.rd_rdy = 1'b1;
      end
      S_BOX: begin
        dma.rd_addr = boxa + (32'(c) * 32'(h) + 32'(y)) * 32'(w);
        dma.rd_len = 32'(w);
        dma.rd_rdy = 1'b1;
      end
      default: ;
    endcase
  end
  assign dma.wr_addr = dst + 32'(ncand_i) * 32'd16;
  assign dma.wr_len = 32'd16;
  assign dma.wr_valid = st == S_WR && !rq_wr && kc == '0;
  assign dma.wr_data = {128'd0, rec};
  assign dma.wr_cnt = 6'd16;
  wire rd_take = dma.rd_valid && dma.rd_rdy;

  // the record of the anchor: corners and words
  wire signed [31:0] cx = $signed({15'd0, x, 1'b1}) <<< 3;
  wire signed [31:0] cy = $signed({15'd0, y, 1'b1}) <<< 3;
  // (every operand an argument: a continuous assignment re-evaluates only on its arguments)
  function automatic logic [15:0] corner(input logic signed [31:0] v, input logic [15:0] ofs, input logic [15:0] lim,
                                         input logic [7:0] sv, input logic [31:0] iv);
    logic signed [31:0] pp;
    logic signed [63:0] t;
    pp = ((v * $signed({24'd0, sv})) >>> 4) - $signed({16'd0, ofs});
    t = (64'(pp) * $signed({32'd0, iv}) + 64'sd32768) >>> 16;
    if (t > $signed({48'd0, lim}) - 64'sd1) t = $signed({48'd0, lim}) - 64'sd1;
    if (t < 0) t = 0;
    corner = t[15:0];
  endfunction
  wire [15:0] cx0 = corner(cx - 32'(sd[0]), ox, fw, stride, inv);
  wire [15:0] cy0 = corner(cy - 32'(sd[1]), oy, fh, stride, inv);
  wire [15:0] cx1 = corner(cx + 32'(sd[2]), ox, fw, stride, inv);
  wire [15:0] cy1 = corner(cy + 32'(sd[3]), oy, fh, stride, inv);
  wire [7:0]  score = siglut[8'(best[XB'(x)]) ^ 8'h80];
  wire [31:0] word2 = 32'(bcls[XB'(x)]) | (32'(score) << 8) | (32'(level) << 16);

  // the box value of bin r of the current side for the anchor
  wire [$clog2(NB)-1:0] bv_row = $clog2(NB)'(32'(side) * 32'(reg_n) + 32'(r));
  wire signed [7:0] bv = $signed(bb_q[5'(x)]);
  wire [7:0]  dlt = 8'(16'($signed(mx) - $signed(bv)));          // max - v (0 .. 255)
  wire [15:0] e = explut[dlt];

  always_comb begin
    for (int i = 0; i < 32; i++) begin
      bb_we[i] = rd_take && st == S_BOX && 32'(kc) * 32 + i < W_MAX;
      bb_wa[i] = BBA'({$clog2(NB)'(c), $clog2(W_MAX / 32)'(kc)});
      bb_wd[i] = dma.rd_data[8*i +: 8];
      bb_ra[i] = BBA'({bv_row, $clog2(W_MAX / 32)'(x >> 5)});
    end
  end
  npu_lane_mem #(.LANES(32), .DEPTH(1 << BBA), .W(8)) u_bb (
    .clk,
    .we_i(bb_we),
    .waddr_i(bb_wa),
    .wdata_i(bb_wd),
    .raddr_i(bb_ra),
    .rdata_o(bb_q)
  );
  always_ff @(posedge clk) begin
    if (rd_take && st == S_LUT) begin
      for (int i = 0; i < 16; i++)
        if (32'(kc) * 16 + i < 256) explut[8'(32'(kc) * 16 + i)] <= dma.rd_data[16*i +: 16];
      if (kc >= 10'd16)
        for (int i = 0; i < 32; i++) siglut[8'((32'(kc) - 16) * 32 + i)] <= dma.rd_data[8*i +: 8];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      boxa <= '0;
      clsa <= '0;
      dst <= '0;
      lut_a <= '0;
      inv <= '0;
      reg_n <= '0;
      nc <= '0;
      h <= '0;
      w <= '0;
      ox <= '0;
      oy <= '0;
      fw <= '0;
      fh <= '0;
      stride <= '0;
      level <= '0;
      thresh <= '0;
      y <= '0;
      x <= '0;
      c <= '0;
      side <= '0;
      r <= '0;
      kc <= '0;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      err <= 1'b0;
      full <= 1'b0;
      mx <= '0;
      num <= '0;
      den <= '0;
      quo <= '0;
      dstep <= '0;
      for (int i = 0; i < 4; i++) sd[i] <= '0;
      rec <= '0;
      cand_o <= 1'b0;
    end else begin
      cand_o <= 1'b0;
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      unique case (st)
        S_IDLE: if (start_i) begin
          boxa <= dw(1);
          clsa <= dw(2);
          dst <= dw(3);
          lut_a <= dw(12);
          reg_n <= d_i[32*4+16 +: 16];
          nc <= d_i[32*4+0 +: 16];
          h <= d_i[32*5+16 +: 16];
          w <= d_i[32*5+0 +: 16];
          stride <= d_i[32*8+0 +: 8];
          level <= d_i[32*8+8 +: 8];
          thresh <= d_i[32*13+7] ? $signed({2'b00, dw(13)}) - 34'sd256 : $signed({2'b00, dw(13)});
          ox <= gb[47:32];
          oy <= gb[63:48];
          fw <= geom_i[63:48];
          fh <= geom_i[79:64];
          inv <= bank2 ? inv_i[63:32] : inv_i[31:0];
          err <= 1'b0;
          full <= 32'(ncand_i) >= 32'(CAND_MAX);
          y <= '0;
          kc <= '0;
          if (d_i[32*4+16 +: 16] == '0 || d_i[32*4+0 +: 16] == '0 || 32'(d_i[32*4+16 +: 16]) > 32'(REG_MAX) ||
              32'(d_i[32*5+0 +: 16]) > 32'(W_MAX)) begin
            err <= 1'b1;
            st <= S_DONE;
          end else if (d_i[32*5+16 +: 16] == '0 || d_i[32*5+0 +: 16] == '0 || 32'(ncand_i) >= 32'(CAND_MAX)) begin
            st <= S_DONE;                        // no anchors, or the candidate buffer full
          end else begin
            rq_rd <= 1'b1;
            st <= S_LUT;
          end
        end
        S_LUT: if (rd_take) begin
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            c <= '0;
            rq_rd <= 1'b1;
            st <= S_CLS;
          end
        end
        S_ROW: begin
          kc <= '0;
          c <= '0;
          rq_rd <= 1'b1;
          st <= S_CLS;
        end
        S_CLS: if (rd_take) begin                // class c of the row: best / class per anchor
          for (int i = 0; i < 32; i++)
            if (32'(kc) * 32 + i < 32'(w) && (c == '0 || $signed(dma.rd_data[8*i +: 8]) > best[XB'(32'(kc) * 32 + i)])) begin
              best[XB'(32'(kc) * 32 + i)] <= $signed(dma.rd_data[8*i +: 8]);
              bcls[XB'(32'(kc) * 32 + i)] <= c;
            end
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            rq_rd <= 1'b1;
            if (c + 16'd1 < nc) c <= c + 16'd1;
            else begin
              c <= '0;
              st <= S_BOX;
            end
          end
        end
        S_BOX: if (rd_take) begin                // box row c (written above)
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            if (c + 16'd1 < 16'(4 * 32'(reg_n))) begin
              c <= c + 16'd1;
              rq_rd <= 1'b1;
            end else begin
              x <= '0;
              st <= S_ANC;
            end
          end
        end
        S_ANC: begin                             // the next kept anchor of the row
          if (x == w) begin
            if (y + 16'd1 < h) begin
              y <= y + 16'd1;
              st <= S_ROW;
            end else begin
              st <= S_DONE;
            end
          end else if ($signed({{26{best[XB'(x)][7]}}, best[XB'(x)]}) >= thresh) begin
            if (full) begin
              st <= S_DONE;                      // the model stops at CAND_MAX
            end else begin
              side <= '0;
              r <= '0;
              mx <= -8'sd128;
              st <= S_MX;
            end
          end else begin
            x <= x + 16'd1;
          end
        end
        S_MX: begin                              // the side's maximum
          if (bv > mx) mx <= bv;
          if (32'(r) + 1 == 32'(reg_n)) begin
            r <= '0;
            num <= '0;
            den <= '0;
            st <= S_SUM;
          end else begin
            r <= r + 5'd1;
          end
        end
        S_SUM: begin                             // sum e r, sum e
          num <= num + 28'(e) * 28'(r);
          den <= den + 21'(e);
          if (32'(r) + 1 == 32'(reg_n)) begin
            r <= '0;
            dstep <= '0;
            quo <= '0;
            st <= S_DIV;
          end else begin
            r <= r + 5'd1;
          end
        end
        S_DIV: begin                             // (num << 4) / den: the 8 quotient bits, MSB first
          if (den != '0 && 32'(quo | qbit) * 32'(den) <= {num, 4'd0}) quo <= quo | qbit;
          if (dstep == 5'd7) begin
            st <= S_NEXT;
          end
          dstep <= dstep + 5'd1;
        end
        S_NEXT: begin                            // the side's distance; the next side or the record
          sd[side] <= 8'(quo);
          if (side == 2'd3) begin
            st <= S_REC;
          end else begin
            side <= side + 2'd1;
            r <= '0;
            mx <= -8'sd128;
            st <= S_MX;
          end
        end
        S_REC: begin
          rec <= {32'd0, word2, cy1, cy0, cx1, cx0};
          kc <= '0;
          rq_wr <= 1'b1;
          st <= S_WR;
        end
        S_WR: begin
          if (dma.wr_valid && dma.wr_rdy) kc <= 10'd1;
          if (dma.wr_done) begin
            cand_o <= 1'b1;
            full <= 32'(ncand_i) + 1 >= 32'(CAND_MAX);
            x <= x + 16'd1;
            st <= S_ANC;
          end
        end
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign done_o = st == S_DONE;
  assign err_o = st == S_DONE && err;
  wire unused_ok = &{1'b0, d_i, geom_i, inv_i, gb, 1'b0};
endmodule
