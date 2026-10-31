// ***************
// Filename: npu_conv.sv
// Author: FPGA Cores 4 U
// Description: CONV engine of the NPU (operation 1 of model/npu_model.py;
//   the DDR result equals the model's bit for bit). Version 1.2.1.
//   Input C x H x W (d[4], d[5]) at d[1], weights O x C x k x k INT8 at d[9],
//   bias O x INT32 at d[10], per output channel (M, S) INT32 pairs at d[11],
//   optional LUT (256 INT8) at d[12] (0: none); k = d[8][7:0], stride s =
//   d[8][15:8], padding p = d[8][23:16]; output O x Ho x Wo (d[6], d[7]) at
//   d[3]: acc = sum(w x) + bias (INT32), q = clamp((acc M + 2^(S-1)) >> S,
//   -128, 127) (64-bit product), then LUT[q + 128] if a LUT is given.
//   Output stationary on a PE_P x PE_O array (mac_array: PE_P output pixels
//   of a row by PE_O output channels, one INT8 x INT8 product each per
//   clock): per tile of PE_O output channels the weight rows (C k k bytes
//   each) into PE_O lane memories, the tile's bias and (M, S); per output
//   row y the C x k input rows (those inside the input; the others add
//   zero) into half y mod 2 of the row buffer by the load side, requested
//   back to back (the DMA queues them), row y + 1 into the other half while
//   row y's strips run; per strip of PE_P output pixels: the accumulators set to the
//   bias, then per (c, dy) a window of the row (NWW words, read in one
//   clock from the NB-bank row buffer, the next window's read issued in the
//   last MAC clock of the current one) and k MAC clocks (dx): k clocks per
//   (c, dy) after one clock per strip; then the strip requantised into the
//   output buffer (one output channel of PE_P bytes per clock, once the
//   buffer's previous strip is written), and written from there channel by
//   channel by the write side while the next strip's MACs run (npu.sv posts
//   the writes: none waits for the previous one's B response). The
//   operation ends once the buffer is written.
//   Errors (err_o with done_o, nothing more written): the output shape not
//   the model's ((H + 2p - k) / s + 1 by (W + 2p - k) / s + 1: its assertion),
//   and the buffers / contract: k > K_MAX, s 0 or > 2, C k k > RED_MAX, a row
//   of more than W_MAX bytes, C k rows not fitting the row buffer, S of a
//   channel outside 1 .. 62 (checked when its tile is loaded).
//   Parameters: PE_P, PE_O (the array), RED_MAX (C k k), W_MAX (input row
//   bytes), RB_WORDS (one half of the row buffer, 32-byte words, a
//   multiple of NB = 8), K_MAX (3).
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_conv #(
  parameter int PE_P     = 64,                   // output pixels per strip
  parameter int PE_O     = 64,                   // output channels per tile
  parameter int RED_MAX  = 4608,                 // C k k (512 x 3 x 3)
  parameter int W_MAX    = 2048,                 // input row bytes
  parameter int RB_WORDS = 3072,                 // row buffer: 96 KB
  parameter int K_MAX    = 3                     // kernel size
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  input  logic          start_i,                 // start on d_i
  input  logic [511:0]  d_i,                     // the descriptor, word k in [32k +: 32]
  output logic          done_o,                  // one clock: the operation done
  output logic          err_o,                   // with done_o: a bad parameter
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam int LW   = RED_MAX / 32;            // lane memory words
  localparam int NWW  = ((PE_P - 1) * 2 + K_MAX + 31 + 31) / 32;   // window words (stride <= 2)
  localparam int LWA  = (LW > 1) ? $clog2(LW) : 1;
  localparam int OB   = (PE_O > 1) ? $clog2(PE_O) : 1;
  localparam int NB   = 8;                       // row buffer banks (word address mod NB)
  localparam int NBA  = $clog2(NB);
  localparam int RBB  = 2 * RB_WORDS / NB;       // words per bank (both halves)
  localparam int RBBA = $clog2(RBB);
  if (RED_MAX % 32 != 0 || W_MAX % 32 != 0 || PE_P < 1 || PE_O < 1 || K_MAX < 1 || NWW > NB ||
      RB_WORDS % NB != 0) begin : g_bad
    $error("npu_conv: RED_MAX and W_MAX multiples of 32, RB_WORDS of NB, a window of at most NB words");
  end

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  typedef enum logic [4:0] {S_IDLE, S_LUT, S_TILE, S_WLD, S_BIAS, S_QNT, S_ROW, S_STRIP, S_FETCH, S_MAC, S_REQ,
                            S_NEXT, S_DRAIN, S_DONE} state_e;
  state_e st;
  // the operation
  logic [31:0]  src, dst, wa, ba, qa, la, cin, cout;
  logic [15:0]  h, w, ho, wo;
  logic [7:0]   k, s, p;
  logic [31:0]  red;                             // C k k
  logic [15:0]  rws;                             // words per row slot
  logic         use_lut, err;
  // loops
  logic [31:0]  o0;                              // the tile's first output channel
  logic [OB:0]  j;                               // lane (weight load, requantisation)
  logic [15:0]  y, x0;
  logic [31:0]  ci;                              // channel (row load, MAC)
  logic [7:0]   dy, dx;
  logic [$clog2(RED_MAX/32 > 16 ? RED_MAX/32 : 16):0] kc;   // chunk index of a read / write
  logic         rq_rd, rq_wr;
  // the write side: the output buffer's strip (written channel by channel while the next strip runs)
  logic [8*PE_P-1:0] ob [PE_O];                  // output channel o of the strip: PE_P bytes
  logic         wb_busy;                         // the buffer holds a strip not yet written
  logic         wb_act;                          // a channel's write in progress
  logic [31:0]  wb_o0, wb_n;                     // its first output channel, channels
  logic [15:0]  wb_y, wb_x0, wb_nx;              // its row, first pixel, pixels
  logic [OB:0]  wb_j;                            // the channel being written
  logic [5:0]   wb_kc;                           // its chunk
  // the load side: output row ld_y's input rows into half ld_h (requests (rci, rdy), data (lci, ldy, lkc))
  logic         ld_busy, ld_rq, ld_h;
  logic [15:0]  ld_y;
  logic [31:0]  rci, lci;
  logic [7:0]   rdy, ldy;
  logic [$clog2(W_MAX/32 > 1 ? W_MAX/32 : 2):0] lkc;
  logic [1:0]   hv;                              // half h holds output row hy[h]'s rows
  logic [15:0]  hy [2];
  // memories
  // weight lanes (npu_lane_mem: lane o = output channel o's weight row, read at one word for every lane)
  logic [PE_O-1:0]           lw_we;
  logic [PE_O-1:0][LWA-1:0]  lw_wa, lw_ra;
  logic [PE_O-1:0][255:0]    lw_wd, lw_q;
  logic signed [31:0] bias [PE_O], qm [PE_O];
  logic [5:0]   qs [PE_O];
  logic [7:0]   lut [256];
  // row buffer: slot (c k + dy), rws words each; word a in bank a mod NB at a / NB (npu_lane_mem, a lane
  // per bank: one write, one read each clock; the read words registered in rb_q)
  logic [NB-1:0]             rb_we;
  logic [NB-1:0][RBBA-1:0]   rb_wa, rb_ra;
  logic [NB-1:0][255:0]      rb_wd, rb_rd;
  logic [255:0] rb_q [NB];                       // the banks' read words
  logic [K_MAX-1:0] rv;                          // tap row dy inside the input
  logic [255:0] win [NWW];                       // the window of the MAC clocks after the first
  logic signed [31:0] acc [PE_P][PE_O];

  // the output shape the model computes
  // (span / s as a shift: only stride 1 and 2 are accepted below - no divider)
  wire        s_two = d_i[32*8+8 +: 8] == 8'd2;
  wire [31:0] ho_sp = 32'(d_i[32*5+16 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) - 32'(d_i[32*8+0 +: 8]);
  wire [31:0] wo_sp = 32'(d_i[32*5+0 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) - 32'(d_i[32*8+0 +: 8]);
  wire [31:0] ho_m = (s_two ? ho_sp >> 1 : ho_sp) + 32'd1;
  wire [31:0] wo_m = (s_two ? wo_sp >> 1 : wo_sp) + 32'd1;
  wire [15:0] rws_m = 16'((32'(d_i[32*5+0 +: 16]) + 31) >> 5);
  wire        shape_ok = d_i[32*8+8 +: 8] != '0 && 32'(d_i[32*5+16 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) >= 32'(d_i[32*8+0 +: 8]) &&
                         32'(d_i[32*5+0 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) >= 32'(d_i[32*8+0 +: 8]) &&
                         ho_m == 32'(d_i[32*7+16 +: 16]) && wo_m == 32'(d_i[32*7+0 +: 16]);

  // ---------------- the window: lane x of the strip, tap dx: byte (x0 + x) s - p + dx of slot (ci k + dy)
  wire signed [17:0] first = 18'($signed({2'b0, x0}) * $signed({10'd0, s})) - 18'($signed({10'd0, p}));
  wire signed [17:0] wfirst = first >>> 5;
  // the (ci, dy) the next window read is for: the current one in S_FETCH, the following one in the last MAC
  // clock (its words arrive for the next clock, the first MAC clock of that window)
  wire        last_dx = dx + 8'd1 == k;
  wire        last_dy = dy + 8'd1 == k;
  wire [31:0] r_ci = (st == S_MAC && last_dx && last_dy) ? ci + 32'd1 : ci;
  wire [7:0]  r_dy = (st == S_MAC && last_dx) ? (last_dy ? 8'd0 : dy + 8'd1) : dy;
  wire signed [31:0] r_word0 = $signed(32'(y[0]) * RB_WORDS + (r_ci * 32'(k) + 32'(r_dy)) * 32'(rws)) +
                               32'(wfirst);      // the window's first word (half y mod 2)
  logic [NBA-1:0]  r_wi [NB];                    // the window word each bank holds
  logic [RBBA-1:0] r_idx [NB];                   // its word in the bank
  logic [NWW-1:0]  r_in;                         // window word i inside the row (others read 0)
  always_comb begin
    for (int b = 0; b < NB; b++) begin
      r_wi[b] = NBA'(b) - NBA'(r_word0);
      r_idx[b] = RBBA'((r_word0 + $signed({1'b0, 31'(r_wi[b])})) >>> NBA);
    end
    for (int i = 0; i < NWW; i++)
      r_in[i] = $signed(32'(wfirst)) + i >= 0 && $signed(32'(wfirst)) + i < $signed({16'd0, rws});
  end
  logic [NBA-1:0] r_rot;                         // bank of window word 0, of the read in flight
  logic [NWW-1:0] r_in_q;
  logic [255:0]   win_rd [NWW];                  // the window just read (the first MAC clock's)
  always_comb begin
    for (int i = 0; i < NWW; i++) win_rd[i] = r_in_q[i] ? rb_q[NBA'(r_rot + NBA'(i))] : '0;
  end
  logic signed [7:0] a_lane [PE_P];
  logic signed [17:0] pos [PE_P], rel [PE_P];
  logic [255:0] wd [PE_P];                       // lane x's window word
  always_comb begin
    for (int x = 0; x < PE_P; x++) begin
      pos[x] = first + 18'($signed({10'd0, dx})) + 18'(x) * 18'($signed({10'd0, s}));
      rel[x] = pos[x] - (wfirst <<< 5);
      wd[x] = (dx == '0) ? win_rd[rel[x][$clog2(NWW*32)-1:5]] : win[rel[x][$clog2(NWW*32)-1:5]];
      a_lane[x] = (pos[x] >= 0 && pos[x] < 18'($signed({2'b0, w})) && rv[dy[$clog2(K_MAX > 1 ? K_MAX : 2)-1:0]])
                  ? $signed(wd[x][8*rel[x][4:0] +: 8]) : 8'sd0;
    end
  end
  // the weight of lane o for (ci, dy, dx): byte ci k k + dy k + dx of its row; the lanes are block RAM: the
  // word of the next MAC clock's (r_ci, r_dy, r_dx) is read one clock ahead (as the window)
  wire [4:0]  wbyte = 5'((ci * 32'(k) + 32'(dy)) * 32'(k) + 32'(dx));   // the current MAC's byte in its word
  wire [7:0]  r_dx = (st == S_MAC && !last_dx) ? dx + 8'd1 : 8'd0;
  wire [31:0] r_widx = (r_ci * 32'(k) + 32'(r_dy)) * 32'(k) + 32'(r_dx);
  logic signed [7:0] w_lane [PE_O];
  logic [255:0] lw_wd_o [PE_O];                  // lane o's weight word
  always_comb begin
    for (int o = 0; o < PE_O; o++) begin
      lw_ra[o] = LWA'(r_widx >> 5);
      lw_wd_o[o] = lw_q[o];                      // (an unpacked copy: Icarus selects bytes of it by a variable)
      w_lane[o] = $signed(lw_wd_o[o][8*wbyte +: 8]);
    end
  end

  // ---------------- requantisation of output channel j: the PE_P bytes of the strip
  logic [7:0]  qb [PE_P];
  logic signed [63:0] qp [PE_P];
  always_comb begin
    for (int x = 0; x < PE_P; x++) begin
      qp[x] = (64'(acc[x][OB'(j)]) * 64'(qm[OB'(j)]) + (64'sd1 <<< (qs[OB'(j)] - 6'd1))) >>> qs[OB'(j)];
      qb[x] = (qp[x] > 64'sd127) ? 8'h7F : (qp[x] < -64'sd128) ? 8'h80 : qp[x][7:0];
      if (use_lut) qb[x] = lut[qb[x] ^ 8'h80];  // index q + 128
    end
  end
  wire [15:0] nx = (32'(wo) - 32'(x0) >= 32'(PE_P)) ? 16'(PE_P) : wo - x0;   // the strip's pixels

  // ---------------- DMA
  assign dma.rd_req = rq_rd || ld_rq;
  assign dma.wr_req = rq_wr;
  always_comb begin
    dma.rd_addr = la;
    dma.rd_len = 32'd256;
    dma.rd_rdy = 1'b0;
    unique case (st)
      S_LUT: dma.rd_rdy = 1'b1;
      S_WLD: begin
        dma.rd_addr = wa + (o0 + 32'(j)) * red;
        dma.rd_len = red;
        dma.rd_rdy = 1'b1;
      end
      S_BIAS: begin
        dma.rd_addr = ba + (o0 << 2);
        dma.rd_len = ((cout - o0 > 32'(PE_O)) ? 32'(PE_O) : cout - o0) << 2;
        dma.rd_rdy = 1'b1;
      end
      S_QNT: begin
        dma.rd_addr = qa + (o0 << 3);
        dma.rd_len = ((cout - o0 > 32'(PE_O)) ? 32'(PE_O) : cout - o0) << 3;
        dma.rd_rdy = 1'b1;
      end
      default: ;
    endcase
    if (ld_busy) begin                           // the load side (the other reads wait for it)
      dma.rd_addr = src + (rci * 32'(h) + 32'(ld_y) * 32'(s) - 32'(p) + 32'(rdy)) * 32'(w);
      dma.rd_len = 32'(w);
      dma.rd_rdy = 1'b1;
    end
  end
  assign dma.wr_addr = dst + ((wb_o0 + 32'(wb_j)) * 32'(ho) + 32'(wb_y)) * 32'(wo) + 32'(wb_x0);
  assign dma.wr_len = 32'(wb_nx);
  assign dma.wr_valid = wb_act && !rq_wr && (32'(wb_kc) << 5) < 32'(wb_nx);
  wire [31:0] wleft = 32'(wb_nx) - (32'(wb_kc) << 5);
  assign dma.wr_cnt = (wleft >= 32'd32) ? 6'd32 : 6'(wleft);
  always_comb begin
    dma.wr_data = '0;
    for (int i = 0; i < 32; i++)
      if (32'(wb_kc) * 32 + i < PE_P) dma.wr_data[8*i +: 8] = ob[OB'(wb_j)][8*(32'(wb_kc) * 32 + i) +: 8];
  end
  wire rd_take = dma.rd_valid && dma.rd_rdy;

  // memories written by the reads, the row buffer read port
  wire [31:0] rl_word = 32'(ld_h) * RB_WORDS + (lci * 32'(k) + 32'(ldy)) * 32'(rws) + 32'(lkc);   // a loaded word
  always_comb begin
    for (int o = 0; o < PE_O; o++) begin
      lw_we[o] = rd_take && st == S_WLD && !ld_busy && 32'(j) == o;
      lw_wa[o] = LWA'(kc);
      lw_wd[o] = dma.rd_data;
    end
    for (int b = 0; b < NB; b++) begin
      rb_we[b] = rd_take && ld_busy && NBA'(rl_word) == NBA'(b);
      rb_wa[b] = RBBA'(rl_word >> NBA);
      rb_wd[b] = dma.rd_data;
      rb_ra[b] = r_idx[b];
    end
  end
  npu_lane_mem #(.LANES(PE_O), .DEPTH(LW), .W(256), .REG_RD(1'b1)) u_lw (
    .clk,
    .we_i(lw_we),
    .waddr_i(lw_wa),
    .wdata_i(lw_wd),
    .raddr_i(lw_ra),
    .rdata_o(lw_q)
  );
  npu_lane_mem #(.LANES(NB), .DEPTH(RBB), .W(256), .REG_RD(1'b1)) u_rb (
    .clk,
    .we_i(rb_we),
    .waddr_i(rb_wa),
    .wdata_i(rb_wd),
    .raddr_i(rb_ra),
    .rdata_o(rb_rd)
  );
  always_comb begin
    for (int b = 0; b < NB; b++) rb_q[b] = rb_rd[b];       // (the registered read words)
  end
  always_ff @(posedge clk) begin
    r_rot <= NBA'(r_word0);
    r_in_q <= r_in;
    if (rd_take) begin
      if (st == S_LUT && !ld_busy)
        for (int i = 0; i < 32; i++) lut[8'(32'(kc) * 32 + i)] <= dma.rd_data[8*i +: 8];
    end
  end

  // the tap rows of output row r inside the input: rows dlo .. dhi (contiguous); none when the mask is 0
  // (every operand an argument: a continuous assignment re-evaluates only on its arguments)
  function automatic logic [K_MAX-1:0] taps_in(input logic [15:0] r, input logic [7:0] tk, input logic [7:0] ts,
                                               input logic [7:0] tp, input logic [15:0] th);
    for (int d = 0; d < K_MAX; d++)
      taps_in[d] = 32'(d) < 32'(tk) && $signed(32'(r) * 32'(ts)) - $signed(32'(tp)) + d >= 0 &&
                   $signed(32'(r) * 32'(ts)) - $signed(32'(tp)) + d < $signed(32'(th));
  endfunction
  function automatic logic [7:0] first_tap(input logic [K_MAX-1:0] m);
    first_tap = '0;
    for (int d = K_MAX - 1; d >= 0; d--) if (m[d]) first_tap = 8'(d);
  endfunction
  function automatic logic [7:0] last_tap(input logic [K_MAX-1:0] m);
    last_tap = '0;
    for (int d = 0; d < K_MAX; d++) if (m[d]) last_tap = 8'(d);
  endfunction
  wire [K_MAX-1:0] ld_in = taps_in(ld_y, k, s, p, h);   // the load side's row
  wire [7:0]  ld_lo = first_tap(ld_in), ld_hi = last_tap(ld_in);
  wire [15:0] y_n = y + 16'd1;
  wire [K_MAX-1:0] y_in = taps_in(y, k, s, p, h), yn_in = taps_in(y_n, k, s, p, h);
  wire        y_ready = hv[y[0]] && hy[y[0]] == y;           // row y loaded into its half
  wire        yn_ready = hv[y_n[0]] && hy[y_n[0]] == y_n;
  // a (M, S) chunk: 4 pairs; a bias chunk: 8 words
  wire [31:0] tile_n = (cout - o0 > 32'(PE_O)) ? 32'(PE_O) : cout - o0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      src <= '0;
      dst <= '0;
      wa <= '0;
      ba <= '0;
      qa <= '0;
      la <= '0;
      cin <= '0;
      cout <= '0;
      h <= '0;
      w <= '0;
      ho <= '0;
      wo <= '0;
      k <= '0;
      s <= '0;
      p <= '0;
      red <= '0;
      rws <= '0;
      use_lut <= 1'b0;
      err <= 1'b0;
      o0 <= '0;
      j <= '0;
      y <= '0;
      x0 <= '0;
      ci <= '0;
      dy <= '0;
      dx <= '0;
      kc <= '0;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      ld_busy <= 1'b0;
      ld_rq <= 1'b0;
      ld_h <= 1'b0;
      ld_y <= '0;
      rci <= '0;
      lci <= '0;
      rdy <= '0;
      ldy <= '0;
      lkc <= '0;
      hv <= '0;
      for (int i = 0; i < 2; i++) hy[i] <= '0;
      rv <= '0;
      wb_busy <= 1'b0;
      wb_act <= 1'b0;
      wb_o0 <= '0;
      wb_n <= '0;
      wb_y <= '0;
      wb_x0 <= '0;
      wb_nx <= '0;
      wb_j <= '0;
      wb_kc <= '0;
    end else begin
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      // the write side: channel after channel of the buffered strip
      if (wb_busy && !wb_act) begin
        wb_act <= 1'b1;
        wb_kc <= '0;
        rq_wr <= 1'b1;
      end
      if (wb_act && dma.wr_valid && dma.wr_rdy) wb_kc <= wb_kc + 1'b1;
      if (wb_act && dma.wr_done) begin
        wb_act <= 1'b0;
        if (32'(wb_j) + 1 < wb_n) wb_j <= wb_j + 1'b1;
        else wb_busy <= 1'b0;
      end
      // the load side: requests back to back, the data in request order
      if (ld_busy) begin
        if (ld_rq && dma.rd_ready) begin
          if (rdy == ld_hi) begin
            rdy <= ld_lo;
            rci <= rci + 32'd1;
            ld_rq <= rci + 32'd1 != cin;
          end else begin
            rdy <= rdy + 8'd1;
          end
        end
        if (rd_take) begin
          lkc <= lkc + 1'b1;
          if (dma.rd_last) begin
            lkc <= '0;
            if (ldy == ld_hi) begin
              ldy <= ld_lo;
              lci <= lci + 32'd1;
              if (lci + 32'd1 == cin) begin      // the row's last input row in
                ld_busy <= 1'b0;
                hv[ld_h] <= 1'b1;
              end
            end else begin
              ldy <= ldy + 8'd1;
            end
          end
        end
      end
      unique case (st)
        S_IDLE: if (start_i) begin
          src <= dw(1);
          dst <= dw(3);
          wa <= dw(9);
          ba <= dw(10);
          qa <= dw(11);
          la <= dw(12);
          use_lut <= dw(12) != '0;
          cin <= dw(4);
          cout <= dw(6);
          h <= d_i[32*5+16 +: 16];
          w <= d_i[32*5+0 +: 16];
          ho <= d_i[32*7+16 +: 16];
          wo <= d_i[32*7+0 +: 16];
          k <= d_i[32*8+0 +: 8];
          s <= d_i[32*8+8 +: 8];
          p <= d_i[32*8+16 +: 8];
          red <= dw(4) * 32'(d_i[32*8+0 +: 8]) * 32'(d_i[32*8+0 +: 8]);
          rws <= rws_m;
          o0 <= '0;
          err <= 1'b0;
          kc <= '0;
          if (!shape_ok || d_i[32*8+0 +: 8] == '0 || 32'(d_i[32*8+0 +: 8]) > 32'(K_MAX) || d_i[32*8+8 +: 8] > 8'd2 ||
              dw(4) * 32'(d_i[32*8+0 +: 8]) * 32'(d_i[32*8+0 +: 8]) > 32'(RED_MAX) || 32'(d_i[32*5+0 +: 16]) > 32'(W_MAX) ||
              dw(4) * 32'(d_i[32*8+0 +: 8]) * 32'(rws_m) > 32'(RB_WORDS)) begin
            err <= 1'b1;
            st <= S_DONE;
          end else if (dw(6) == '0 || d_i[32*7+16 +: 16] == '0 || d_i[32*7+0 +: 16] == '0) begin
            st <= S_DONE;
          end else if (dw(12) != '0) begin
            rq_rd <= 1'b1;
            st <= S_LUT;
          end else begin
            st <= S_TILE;
          end
        end
        S_LUT: if (rd_take) begin
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            st <= S_TILE;
          end
        end
        // a tile: the weight rows of its channels, then bias and (M, S)
        S_TILE: if (!ld_busy) begin              // (the tile's own reads only with the load side idle)
          hv <= '0;                              // the halves hold no row of this tile
          j <= '0;
          kc <= '0;
          rq_rd <= 1'b1;
          if (cin == '0) st <= S_BIAS;    // no inputs: the sums are the biases
          else st <= S_WLD;
        end
        S_WLD: if (rd_take) begin
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            rq_rd <= 1'b1;
            if (32'(j) + 1 < tile_n) j <= j + 1'b1;
            else st <= S_BIAS;
          end
        end
        S_BIAS: if (rd_take) begin
          for (int i = 0; i < 8; i++)
            if (32'(kc) * 8 + i < PE_O) bias[OB'(32'(kc) * 8 + i)] <= $signed(dma.rd_data[32*i +: 32]);
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            rq_rd <= 1'b1;
            st <= S_QNT;
          end
        end
        S_QNT: if (rd_take) begin
          for (int i = 0; i < 4; i++)
            if (32'(kc) * 4 + i < PE_O) begin
              qm[OB'(32'(kc) * 4 + i)] <= $signed(dma.rd_data[64*i +: 32]);
              qs[OB'(32'(kc) * 4 + i)] <= 6'(dma.rd_data[64*i + 32 +: 32]);
              if (32'(kc) * 4 + i < tile_n &&
                  ($signed(dma.rd_data[64*i + 32 +: 32]) < 1 || $signed(dma.rd_data[64*i + 32 +: 32]) > 62))
                err <= 1'b1;
            end
          kc <= kc + 1'b1;
          if (dma.rd_last) begin
            kc <= '0;
            y <= '0;
            st <= S_ROW;
          end
        end
        // an output row: wait for its rows in half y mod 2 (loading them first if not yet requested), then
        // the strips, with row y + 1 loading into the other half
        S_ROW: begin
          if (err) begin
            st <= S_DRAIN;
          end else if (y_ready || cin == '0 || y_in == '0) begin   // (no input rows: the windows add 0)
            rv <= y_in;
            x0 <= '0;
            st <= S_STRIP;
            if (y_n < ho && cin != '0 && yn_in != '0 && !ld_busy && !yn_ready) begin
              ld_busy <= 1'b1;                   // the next row into the other half
              ld_rq <= 1'b1;
              ld_h <= y_n[0];
              ld_y <= y_n;
              hv[y_n[0]] <= 1'b0;
              hy[y_n[0]] <= y_n;
              rci <= '0;
              lci <= '0;
              rdy <= first_tap(yn_in);
              ldy <= first_tap(yn_in);
              lkc <= '0;
            end
          end else if (!ld_busy) begin           // row y not loaded nor loading: load it
            ld_busy <= 1'b1;
            ld_rq <= 1'b1;
            ld_h <= y[0];
            ld_y <= y;
            hv[y[0]] <= 1'b0;
            hy[y[0]] <= y;
            rci <= '0;
            lci <= '0;
            rdy <= first_tap(y_in);
            ldy <= first_tap(y_in);
            lkc <= '0;
          end
        end
        // a strip: accumulators from the bias, then (ci, dy) windows and taps
        S_STRIP: begin
          for (int x = 0; x < PE_P; x++)
            for (int o = 0; o < PE_O; o++) acc[x][o] <= bias[o];
          ci <= '0;
          dy <= '0;
          if (cin == '0) st <= S_REQ;
          else st <= S_FETCH;
          j <= '0;
        end
        S_FETCH: begin                           // the strip's first window read (r_ci / r_dy = ci / dy)
          dx <= '0;
          st <= S_MAC;
        end
        S_MAC: begin                             // tap dx of window (ci, dy); a row outside the input adds 0
          for (int x = 0; x < PE_P; x++)
            for (int o = 0; o < PE_O; o++) acc[x][o] <= acc[x][o] + 32'(a_lane[x]) * 32'(w_lane[o]);
          if (dx == '0) for (int i = 0; i < NWW; i++) win[i] <= win_rd[i];
          dx <= dx + 8'd1;
          if (last_dx) begin
            dx <= '0;
            if (last_dy) begin
              dy <= '0;
              if (ci + 32'd1 == cin) st <= S_REQ;
              else ci <= ci + 32'd1;
            end else begin
              dy <= dy + 8'd1;
            end
          end
        end
        // requantise the strip into the output buffer, channel j per clock, once its last strip is written
        S_REQ: if (!wb_busy) begin
          for (int x = 0; x < PE_P; x++) ob[OB'(j)][8*x +: 8] <= qb[x];
          if (32'(j) + 1 < tile_n) begin
            j <= j + 1'b1;
          end else begin
            wb_busy <= 1'b1;
            wb_o0 <= o0;
            wb_n <= tile_n;
            wb_y <= y;
            wb_x0 <= x0;
            wb_nx <= nx;
            wb_j <= '0;
            st <= S_NEXT;
          end
        end
        S_NEXT: begin                            // the next strip, row, tile
          j <= '0;
          if (32'(x0) + PE_P < 32'(wo)) begin
            x0 <= x0 + 16'(PE_P);
            st <= S_STRIP;
          end else if (y + 16'd1 < ho) begin
            y <= y + 16'd1;
            st <= S_ROW;
          end else if (o0 + 32'(PE_O) < cout) begin
            o0 <= o0 + 32'(PE_O);
            st <= S_TILE;
          end else begin
            st <= S_DRAIN;
          end
        end
        S_DRAIN: if (!wb_busy && !ld_busy) st <= S_DONE;   // the last strip written (no load in flight)
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  assign done_o = st == S_DONE;
  assign err_o = st == S_DONE && err;
  wire unused_ok = &{1'b0, d_i, 1'b0};
endmodule
