// ***************
// Filename: npu_nms.sv
// Author: FPGA Cores 4 U
// Description: NMS engine of the NPU (operation 8 of model/npu_model.py; the
//   detection list and its count equal the model's bit for bit). Version
//   1.1.0.
//   The run's ncand_i candidates (16-byte records: x0 | x1 << 16, y0 |
//   y1 << 16, class | score << 8 | level << 16, 0) are read from d[1] into
//   the candidate memory; in order of score (highest first, equal scores in
//   index order: a counting sort) each is kept unless a kept one overlaps it:
//   the same class by more than d[13] per mille of IoU, another class by
//   more than d[14], or (d[15] not 0) the same class covering more than
//   d[15] per mille of the smaller box (72-bit products, exact as the
//   model's integers); the kept ones ranked by (area, score, index) - the
//   largest first - and the first DET_MAX records written to DET_ADDR (one
//   write). det_o (with done_o) is their count (DET_COUNT).
//   The candidate memory is block RAM: even and odd records in two banks
//   (a DMA chunk's two records: one write each), two registered read ports
//   (A, B); every loop issues the next record's read while it uses the
//   current one (one record or comparison per clock, the read one clock
//   ahead).
//   det_addr_i / det_max_i: the run's DET_ADDR / DET_MAX (npu.sv takes them
//   at the start of the run, as the model).
//   Parameters: CAND_MAX (the candidate memory, a power of two >= 2).
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_nms #(
  parameter int CAND_MAX = 2048                  // candidates per run
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  input  logic          start_i,                 // start on d_i
  input  logic [511:0]  d_i,                     // the descriptor, word k in [32k +: 32]
  input  logic [11:0]   ncand_i,                 // the run's candidates
  input  logic [31:0]   det_addr_i,              // DET_ADDR of the run
  input  logic [15:0]   det_max_i,               // DET_MAX of the run
  output logic          done_o,                  // one clock: the operation done
  output logic          err_o,                   // with done_o: never (no parameter is rejected)
  output logic [15:0]   det_o,                   // with done_o: the detections written
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam int CB = $clog2(CAND_MAX);
  if (CAND_MAX < 2 || (CAND_MAX & (CAND_MAX - 1)) != 0) begin : g_bad
    $error("npu_nms: CAND_MAX a power of two >= 2");
  end
  typedef enum logic [3:0] {S_IDLE, S_LOAD, S_HIST, S_PFX, S_PLACE, S_PICK, S_CMP, S_RANK, S_RCMP, S_WR,
                            S_DONE} state_e;
  state_e st;

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  logic [CB:0]  order [CAND_MAX];                // indices by score
  logic [CB:0]  keep [CAND_MAX];                 // kept indices, in keep order
  logic [CB:0]  outp [CAND_MAX];                 // kept indices by rank (the first DET_MAX)
  logic [CB:0]  hist [256];                      // per score: count, then the next place
  logic [CB:0]  n, kn, t, u, oi;                 // candidates, kept, loop indices
  logic [CB:0]  rank;
  logic [8:0]   sc;                              // score being summed
  logic [31:0]  src, same, other, cont, daddr;
  logic [15:0]  dmax;
  logic [CB:0]  nout;                            // records written
  logic [10:0]  kc;
  logic         rq_rd, rq_wr;
  logic [CB:0]  tq;                              // HIST / PLACE: the record read last clock
  logic         vq;                              // its read was issued
  logic         dv;                              // WR: the records of chunk kc are read

  // ---------------- the candidate memory: record r in bank r[0] at r >> 1; ports A and B (read r, its
  // record the clock after)
  logic [CB:0]   a_idx, b_idx;                   // the records the ports read this clock
  logic          a_sel, b_sel;                   // the banks of the records on the outputs
  logic [127:0]  ae, ao, be, bo;
  wire           rd_take = dma.rd_valid && dma.rd_rdy;
  wire  [CB-2:0] ld_w = (CB-1)'(kc);             // a chunk's record pair: word kc of each bank
  npu_ram_1w2r #(.DEPTH(CAND_MAX / 2), .W(128)) u_cme (
    .clk,
    .we_i(rd_take && 32'(kc) * 2 < CAND_MAX),
    .waddr_i(ld_w),
    .wdata_i(dma.rd_data[127:0]),
    .raddr_a_i((CB-1)'(a_idx >> 1)),
    .rdata_a_o(ae),
    .raddr_b_i((CB-1)'(b_idx >> 1)),
    .rdata_b_o(be)
  );
  npu_ram_1w2r #(.DEPTH(CAND_MAX / 2), .W(128)) u_cmo (
    .clk,
    .we_i(rd_take && 32'(kc) * 2 + 1 < CAND_MAX),
    .waddr_i(ld_w),
    .wdata_i(dma.rd_data[255:128]),
    .raddr_a_i((CB-1)'(a_idx >> 1)),
    .rdata_a_o(ao),
    .raddr_b_i((CB-1)'(b_idx >> 1)),
    .rdata_b_o(bo)
  );
  always_ff @(posedge clk) begin
    a_sel <= a_idx[0];
    b_sel <= b_idx[0];
  end
  wire [127:0] qa = a_sel ? ao : ae;
  wire [127:0] qb = b_sel ? bo : be;

  // what each loop reads: its current record on the outputs, the next one's address issued
  wire [CB:0]  i_idx = order[CB'(oi)];
  always_comb begin
    a_idx = t;                                   // HIST / PLACE: record t (used the clock after)
    b_idx = '0;
    unique case (st)
      S_PICK, S_CMP: begin                       // the candidate (A, held) against kept record t (B)
        a_idx = i_idx;
        b_idx = (st == S_PICK) ? keep[0] : keep[CB'(t + 1'b1)];
      end
      S_RANK, S_RCMP: begin                      // kept record t (A, held) against kept record u (B)
        a_idx = keep[CB'(t)];
        b_idx = (st == S_RANK) ? keep[0] : keep[CB'(u + 1'b1)];
      end
      S_WR: begin                                // the chunk's two records by rank
        a_idx = outp[CB'(32'(kc) * 2)];
        b_idx = outp[CB'(32'(kc) * 2 + 1)];
      end
      default: ;
    endcase
  end

  // a record's fields
  function automatic logic signed [35:0] area_of(input logic [63:0] r);   // (x1 - x0 + 1) (y1 - y0 + 1)
    logic signed [17:0] dx, dy;
    dx = $signed({2'b0, r[31:16]}) - $signed({2'b0, r[15:0]}) + 18'sd1;
    dy = $signed({2'b0, r[63:48]}) - $signed({2'b0, r[47:32]}) + 18'sd1;
    area_of = 36'(dx) * 36'(dy);
  endfunction

  // the candidate under test (ri) and the kept one compared (rj)
  wire [127:0]  ri = qa;
  wire [127:0]  rj = qb;
  wire signed [17:0] ix = 18'($signed({2'b0, (ri[31:16] < rj[31:16]) ? ri[31:16] : rj[31:16]})) -
                          18'($signed({2'b0, (ri[15:0] > rj[15:0]) ? ri[15:0] : rj[15:0]})) + 18'sd1;
  wire signed [17:0] iy = 18'($signed({2'b0, (ri[63:48] < rj[63:48]) ? ri[63:48] : rj[63:48]})) -
                          18'($signed({2'b0, (ri[47:32] > rj[47:32]) ? ri[47:32] : rj[47:32]})) + 18'sd1;
  wire signed [35:0] ai = area_of(ri[63:0]), aj = area_of(rj[63:0]);
  wire signed [71:0] inter = 72'(ix) * 72'(iy);
  wire signed [71:0] uni = 72'(ai) + 72'(aj) - inter;
  wire        same_cls = ri[71:64] == rj[71:64];
  wire signed [71:0] lim = same_cls ? $signed({40'd0, same}) : $signed({40'd0, other});
  wire signed [71:0] amin = (ai < aj) ? 72'(ai) : 72'(aj);
  wire        overlap = ix > 0 && iy > 0;
  wire        by_iou = overlap && inter * 72'sd1000 > lim * uni;
  wire        by_part = overlap && cont != '0 && same_cls && inter * 72'sd1000 > $signed({40'd0, cont}) * amin;

  // ranking: is kept candidate m (rank loop u) before k (outer t)?
  wire [127:0]  rk = qa;
  wire [127:0]  rm = qb;
  wire signed [35:0] ak = area_of(rk[63:0]), am = area_of(rm[63:0]);
  wire        m_first = am > ak || (am == ak && (rm[79:72] > rk[79:72] ||
                       (rm[79:72] == rk[79:72] && keep[CB'(u)] < keep[CB'(t)])));

  // the score of the record read last clock (HIST / PLACE)
  wire [7:0]   q_sc = qa[79:72];

  // DMA
  assign dma.rd_req = rq_rd;
  assign dma.rd_addr = src;
  assign dma.rd_len = 32'(n) << 4;
  assign dma.rd_rdy = st == S_LOAD;
  assign dma.wr_req = rq_wr;
  assign dma.wr_addr = daddr;
  assign dma.wr_len = 32'(nout) << 4;
  assign dma.wr_valid = st == S_WR && !rq_wr && dv && (32'(kc) << 1) < 32'(nout);
  assign dma.wr_cnt = (32'(kc) * 2 + 1 < 32'(nout)) ? 6'd32 : 6'd16;
  assign dma.wr_data = {qb, qa};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      n <= '0;
      kn <= '0;
      t <= '0;
      u <= '0;
      oi <= '0;
      rank <= '0;
      sc <= '0;
      src <= '0;
      same <= '0;
      other <= '0;
      cont <= '0;
      daddr <= '0;
      dmax <= '0;
      nout <= '0;
      kc <= '0;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      det_o <= '0;
      tq <= '0;
      vq <= 1'b0;
      dv <= 1'b0;
    end else begin
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      dv <= st == S_WR && !(dma.wr_valid && dma.wr_rdy);   // the reads of an unchanged chunk index
      unique case (st)
        S_IDLE: if (start_i) begin
          n <= (CB+1)'(ncand_i);
          src <= dw(1);
          same <= dw(13);
          other <= dw(14);
          cont <= dw(15);
          daddr <= det_addr_i;
          dmax <= det_max_i;
          kn <= '0;
          kc <= '0;
          for (int s = 0; s < 256; s++) hist[s] <= '0;
          if (ncand_i == '0) begin
            det_o <= '0;
            st <= S_DONE;
          end else begin
            rq_rd <= 1'b1;
            st <= S_LOAD;
          end
        end
        S_LOAD: if (rd_take) begin
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            t <= '0;
            vq <= 1'b0;
            st <= S_HIST;
          end
        end
        S_HIST: begin                            // scores counted (record tq, read last clock)
          vq <= t != n;
          tq <= t;
          if (t != n) t <= t + 1'b1;
          if (vq) begin
            hist[q_sc] <= hist[q_sc] + 1'b1;
            if (tq + 1'b1 == n) begin
              sc <= 9'd255;
              u <= '0;                           // the running place
              st <= S_PFX;
            end
          end
        end
        S_PFX: begin                             // per score, highest first: its first place
          hist[sc[7:0]] <= u;
          u <= u + hist[sc[7:0]];
          if (sc == '0) begin
            t <= '0;
            vq <= 1'b0;
            st <= S_PLACE;
          end
          sc <= sc - 9'd1;
        end
        S_PLACE: begin                           // every candidate to its place, in index order (stable)
          vq <= t != n;
          tq <= t;
          if (t != n) t <= t + 1'b1;
          if (vq) begin
            order[CB'(hist[q_sc])] <= tq;
            hist[q_sc] <= hist[q_sc] + 1'b1;
            if (tq + 1'b1 == n) begin
              oi <= '0;
              st <= S_PICK;
            end
          end
        end
        S_PICK: begin                            // the next candidate by score against every kept one
          if (oi == n) begin
            t <= '0;
            nout <= (32'(kn) < 32'(dmax)) ? kn : (CB+1)'(dmax);
            st <= S_RANK;
          end else begin
            t <= '0;
            st <= S_CMP;
          end
        end
        S_CMP: begin                             // ri: the candidate, rj: kept record t
          if (t == kn) begin                     // not suppressed: kept
            keep[CB'(kn)] <= i_idx;
            kn <= kn + 1'b1;
            oi <= oi + 1'b1;
            st <= S_PICK;
          end else if (by_iou || by_part) begin  // suppressed
            oi <= oi + 1'b1;
            st <= S_PICK;
          end else begin
            t <= t + 1'b1;
          end
        end
        S_RANK: begin                            // kept candidate t: its rank among the kept
          if (t == kn) begin
            kc <= '0;
            det_o <= 16'(nout);
            if (nout == '0) st <= S_DONE;
            else begin
              rq_wr <= 1'b1;
              st <= S_WR;
            end
          end else begin
            u <= '0;
            rank <= '0;
            st <= S_RCMP;
          end
        end
        S_RCMP: begin                            // rk: kept record t, rm: kept record u
          if (u == kn) begin
            if (32'(rank) < 32'(dmax)) outp[CB'(rank)] <= keep[CB'(t)];
            t <= t + 1'b1;
            st <= S_RANK;
          end else begin
            if (m_first) rank <= rank + 1'b1;
            u <= u + 1'b1;
          end
        end
        S_WR: begin                              // the records by rank, two per chunk
          if (dma.wr_valid && dma.wr_rdy) kc <= kc + 1'b1;
          if (dma.wr_done) st <= S_DONE;
        end
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign done_o = st == S_DONE;
  assign err_o = 1'b0;
  // not used by the comparisons: the level and word 3 of the records (written as read)
  wire unused_ok = &{1'b0, d_i, ri[127:72], rj[127:72], rk[127:80], rk[71:64], rm[127:80], rm[71:64], qa[127:80],
                     qa[71:0], 1'b0};
endmodule
