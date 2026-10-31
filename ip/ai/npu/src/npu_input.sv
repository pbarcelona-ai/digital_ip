// ***************
// Filename: npu_input.sv
// Author: FPGA Cores 4 U
// Description: INPUT engine of the NPU (operation 6 of model/npu_model.py;
//   the DDR result equals the model's bit for bit). Version 1.0.1.
//   The RGB888 frame (FRAME_ADDR, FRAME_STRIDE bytes per line, FRAME_SIZE)
//   becomes a 3 x NH x NW INT8 letterbox at d[3] (planar R, G, B): NW =
//   d[7][15:0], NH = d[7][31:16] (0: NW); inside the picture (SW x SH at
//   OX, OY: LB_SIZE, LB_OFFSET; with descriptor flag BANK2 the LB2_*
//   registers) the frame scaled by STEP (Q16 frame pixels per input pixel)
//   with the model's bilinear(): source = (((2 i + 1) STEP) >> 1) - 2^15
//   clamped to the frame, i0 = source >> 16, i1 = min(i0 + 1, last), weight
//   (source >> 8) & 255, value (top (256 - fy) + bottom fy + 2^15) >> 16,
//   then >> 1; elsewhere PAD (d[8][23:16], clipped to 127).
//   Per output row: the two frame rows read (picture rows only), the three
//   channel rows computed one pixel per clock, then written (NW bytes each).
//   Errors (err_o with done_o), where the model's numpy fails: the picture
//   outside the input (OX + SW > NW or OY + SH > NH), a stride shorter than
//   a line (FRAME_STRIDE < 3 width, height not 0), a picture on an empty
//   frame; and the buffers: a frame line longer than FW_MAX pixels, an input
//   row longer than NW_MAX.
//   geom_i: the run's frame and letterbox registers (npu.sv takes them at
//   the start of the run, as the model).
//   Parameters: FW_MAX, NW_MAX (pixels; 3 FW_MAX and NW_MAX multiples of 32).
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_input #(
  parameter int FW_MAX = 1920,                   // longest frame line, pixels
  parameter int NW_MAX = 2048                    // longest network input row
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  input  logic          start_i,                 // start on d_i
  input  logic [511:0]  d_i,                     // the descriptor, word k in [32k +: 32]
  // geom_i: {frame addr, stride, size} and per bank {step, offset, size}:
  // [31:0] FRAME_ADDR, [47:32] FRAME_STRIDE, [79:48] FRAME_SIZE, then bank 0 at [175:80], bank 1 at [271:176]
  input  logic [271:0]  geom_i,
  output logic          done_o,                  // one clock: the operation done
  output logic          err_o,                   // with done_o: a bad parameter
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam int FB = 3 * FW_MAX;                // frame row bytes
  if (FB % 32 != 0 || NW_MAX % 32 != 0) begin : g_bad
    $error("npu_input: 3 FW_MAX and NW_MAX multiples of 32");
  end

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  typedef enum logic [3:0] {S_IDLE, S_ROW, S_RD0, S_RD1, S_PIX, S_WR, S_DONE} state_e;
  state_e st;
  logic [31:0]  faddr, step, dst;
  logic [15:0]  stride, fw, fh, ox, oy, sw, sh, nw, nh;
  logic [7:0]   pad;
  logic [15:0]  r, x;                            // output row, pixel
  logic [1:0]   ch;                              // channel being written
  logic         rq_rd, rq_wr, err, pic_row;
  logic [15:0]  y0, y1;
  logic [7:0]   fy;
  logic [47:0]  ax;                              // (2 i + 1) STEP of pixel x (incremental)
  logic [$clog2(FB/32 > NW_MAX/32 ? FB/32 : NW_MAX/32):0] k;   // chunk index
  // the two frame rows and the three output rows: byte-lane memories (npu_lane_mem: lane i = the bytes at
  // positions i mod 32), each lane one write and one read per clock
  localparam int FWA = $clog2(FB / 32), OWA = $clog2(NW_MAX / 32);
  logic [31:0]          fr_we0, fr_we1;
  logic [31:0][FWA-1:0] fr_wa, fr_ra;
  logic [31:0][7:0]     fr_wd, fr_q0, fr_q1;
  logic [95:0]               oc_we;          // channel c, lane i at 32 c + i
  logic [31:0][OWA-1:0]      oc_wa, oc_ra;
  logic [95:0][7:0]          oc_wd, oc_q;

  // an axis's source position (Q16, clamped) from h = ((2 i + 1) STEP) >> 1: (h - 2^15) clamped to
  // [0, (lim - 1) << 16]
  function automatic logic [31:0] src_pos(input logic [46:0] h, input logic [15:0] lim);
    logic signed [48:0] t;
    t = $signed({2'b00, h}) - 49'sd32768;
    if (t < 0) src_pos = '0;
    else if (t > $signed(49'({lim - 16'd1, 16'd0}))) src_pos = {lim - 16'd1, 16'd0};
    else src_pos = t[31:0];
  endfunction

  // the current pixel: inside the picture?
  wire        in_x = x >= ox && x < ox + sw;
  wire [31:0] sx = src_pos(ax[47:1], fw);
  wire [15:0] x0 = sx[31:16];
  wire [15:0] x1 = (x0 + 16'd1 < fw) ? x0 + 16'd1 : x0;
  wire [7:0]  fx = sx[15:8];
  // bilinear per channel
  logic [7:0]  pv [3];
  logic [31:0] top [3], bot [3], bv [3];
  // the 6 tap bytes: positions 3 x0 .. 3 x0 + 5 (x1 is x0 or x0 + 1), each in its own lane
  wire  [31:0] p0 = 3 * 32'(x0);
  wire  [31:0] p1 = 3 * 32'(x1);
  always_comb begin
    for (int i = 0; i < 32; i++) fr_ra[i] = FWA'((p0 + 32'(5'(5'(i) - 5'(p0)))) >> 5);
  end
  function automatic logic [7:0] fr_at(input logic [31:0][7:0] q, input logic [4:0] lane);
    fr_at = q[lane];
  endfunction
  always_comb begin
    for (int c = 0; c < 3; c++) begin
      top[c] = 32'(fr_at(fr_q0, 5'(p0 + 32'(c)))) * (32'd256 - 32'(fx)) + 32'(fr_at(fr_q0, 5'(p1 + 32'(c)))) * 32'(fx);
      bot[c] = 32'(fr_at(fr_q1, 5'(p0 + 32'(c)))) * (32'd256 - 32'(fx)) + 32'(fr_at(fr_q1, 5'(p1 + 32'(c)))) * 32'(fx);
      bv[c] = (top[c] * (32'd256 - 32'(fy)) + bot[c] * 32'(fy) + 32'd32768) >> 16;
      pv[c] = 8'(bv[c] >> 1);
    end
  end
  wire [7:0] pad8 = pad[7] ? 8'h7F : pad;

  // DMA
  assign dma.rd_req = rq_rd;
  assign dma.rd_addr = faddr + 32'((st == S_RD0) ? y0 : y1) * 32'(stride);
  assign dma.rd_len = 32'(fw) * 32'd3;
  assign dma.rd_rdy = st == S_RD0 || st == S_RD1;
  assign dma.wr_req = rq_wr;
  assign dma.wr_addr = dst + (32'(ch) * 32'(nh) + 32'(r)) * 32'(nw);
  assign dma.wr_len = 32'(nw);
  assign dma.wr_valid = st == S_WR && !rq_wr && (32'(k) << 5) < 32'(nw);
  wire [31:0] wleft = 32'(nw) - (32'(k) << 5);
  assign dma.wr_cnt = (wleft >= 32'd32) ? 6'd32 : 6'(wleft);
  always_comb begin
    for (int i = 0; i < 32; i++) dma.wr_data[8*i +: 8] = (ch == 2'd0) ? oc_q[i] : (ch == 2'd1) ? oc_q[32 + i] : oc_q[64 + i];
  end
  // a read chunk: every lane at word k; an output pixel: lane x mod 32 of each channel at word x / 32
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      fr_we0[i] = dma.rd_valid && dma.rd_rdy && st == S_RD0;
      fr_we1[i] = dma.rd_valid && dma.rd_rdy && st == S_RD1;
      fr_wa[i] = FWA'(k);
      fr_wd[i] = dma.rd_data[8*i +: 8];
      oc_wa[i] = OWA'(x >> 5);
      oc_ra[i] = OWA'(k);
      for (int c = 0; c < 3; c++) begin
        oc_we[32*c + i] = st == S_PIX && 5'(x) == 5'(i);
        oc_wd[32*c + i] = (pic_row && in_x) ? pv[c] : pad8;
      end
    end
  end
  npu_lane_mem #(.LANES(32), .DEPTH(FB / 32), .W(8)) u_fr0 (
    .clk,
    .we_i(fr_we0),
    .waddr_i(fr_wa),
    .wdata_i(fr_wd),
    .raddr_i(fr_ra),
    .rdata_o(fr_q0)
  );
  npu_lane_mem #(.LANES(32), .DEPTH(FB / 32), .W(8)) u_fr1 (
    .clk,
    .we_i(fr_we1),
    .waddr_i(fr_wa),
    .wdata_i(fr_wd),
    .raddr_i(fr_ra),
    .rdata_o(fr_q1)
  );
  for (genvar c = 0; c < 3; c++) begin : g_oc
    npu_lane_mem #(.LANES(32), .DEPTH(NW_MAX / 32), .W(8)) u_oc (
      .clk,
      .we_i(oc_we[32*c +: 32]),
      .waddr_i(oc_wa),
      .wdata_i(oc_wd[32*c +: 32]),
      .raddr_i(oc_ra),
      .rdata_o(oc_q[32*c +: 32])
    );
  end

  // the bank's registers
  wire        bank2 = d_i[32*0+8];
  wire [95:0] gb = bank2 ? geom_i[271:176] : geom_i[175:80];
  wire [15:0] g_ox = gb[47:32], g_oy = gb[63:48], g_sw = gb[79:64], g_sh = gb[95:80];
  wire [15:0] g_nw = d_i[32*7+0 +: 16];
  wire [15:0] g_nh = (d_i[32*7+16 +: 16] != '0) ? d_i[32*7+16 +: 16] : d_i[32*7+0 +: 16];
  // the row's vertical position
  wire [15:0] j = r - oy;
  wire [47:0] ay = (48'({j, 1'b0}) + 48'd1) * 48'(step);
  wire [31:0] sy = src_pos(ay[47:1], fh);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      faddr <= '0;
      step <= '0;
      dst <= '0;
      stride <= '0;
      fw <= '0;
      fh <= '0;
      ox <= '0;
      oy <= '0;
      sw <= '0;
      sh <= '0;
      nw <= '0;
      nh <= '0;
      pad <= '0;
      r <= '0;
      x <= '0;
      ch <= '0;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      err <= 1'b0;
      pic_row <= 1'b0;
      y0 <= '0;
      y1 <= '0;
      fy <= '0;
      ax <= '0;
      k <= '0;
    end else begin
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      unique case (st)
        S_IDLE: if (start_i) begin
          faddr <= geom_i[31:0];
          stride <= geom_i[47:32];
          fw <= geom_i[63:48];
          fh <= geom_i[79:64];
          step <= gb[31:0];
          ox <= g_ox;
          oy <= g_oy;
          sw <= g_sw;
          sh <= g_sh;
          nw <= g_nw;
          nh <= g_nh;
          dst <= dw(3);
          pad <= d_i[32*8+16 +: 8];
          r <= '0;
          err <= 1'b0;
          if (32'(g_ox) + 32'(g_sw) > 32'(g_nw) || 32'(g_oy) + 32'(g_sh) > 32'(g_nh) ||
              32'(geom_i[63:48]) > 32'(FW_MAX) || 32'(g_nw) > 32'(NW_MAX) ||
              (geom_i[79:64] != '0 && 32'(geom_i[47:32]) < 32'(geom_i[63:48]) * 32'd3) ||
              (g_sw != '0 && g_sh != '0 && (geom_i[63:48] == '0 || geom_i[79:64] == '0))) begin
            err <= 1'b1;
            st <= S_DONE;
          end else begin
            if (g_nw == '0 || g_nh == '0) st <= S_DONE;
            else st <= S_ROW;
          end
        end
        S_ROW: begin                             // the row's frame rows, if it holds the picture
          pic_row <= r >= oy && r < oy + sh && sw != '0;
          x <= '0;
          ax <= 48'(step);                       // pixel 0: (2 * 0 + 1) STEP
          y0 <= sy[31:16];
          y1 <= (sy[31:16] + 16'd1 < fh) ? sy[31:16] + 16'd1 : sy[31:16];
          fy <= sy[15:8];
          k <= '0;
          if (r >= oy && r < oy + sh && sw != '0) begin
            rq_rd <= 1'b1;
            st <= S_RD0;
          end else begin
            st <= S_PIX;
          end
        end
        S_RD0: if (dma.rd_valid) begin
          k <= k + 1'b1;
          if (dma.rd_last) begin
            k <= '0;
            rq_rd <= 1'b1;
            st <= S_RD1;
          end
        end
        S_RD1: if (dma.rd_valid) begin
          k <= k + 1'b1;
          if (dma.rd_last) begin
            k <= '0;
            st <= S_PIX;
          end
        end
        S_PIX: begin                             // one pixel per clock (written above)
          if (in_x) ax <= ax + 48'({step, 1'b0});
          if (x + 16'd1 == nw) begin
            ch <= '0;
            k <= '0;
            rq_wr <= 1'b1;
            st <= S_WR;
          end
          x <= x + 16'd1;
        end
        S_WR: begin
          if (dma.wr_valid && dma.wr_rdy) k <= k + 1'b1;
          if (dma.wr_done) begin
            k <= '0;
            if (ch != 2'd2) begin
              ch <= ch + 2'd1;
              rq_wr <= 1'b1;
            end else if (r + 16'd1 < nh) begin
              r <= r + 16'd1;
              st <= S_ROW;
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
  // not used: the low bit of (2 i + 1) STEP (halved), the source positions' bits below the weights
  wire unused_ok = &{1'b0, d_i, geom_i, ax[0], sx[7:0], sy[7:0], ay[0], 1'b0};
endmodule
