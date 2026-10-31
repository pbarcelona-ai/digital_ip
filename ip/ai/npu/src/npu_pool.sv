// ***************
// Filename: npu_pool.sv
// Author: FPGA Cores 4 U
// Description: MAXPOOL engine of the NPU (operation 2 of model/npu_model.py;
//   the DDR result equals the model's bit for bit). Version 1.0.1.
//   C = d[4], H x W = d[5] (H << 16 | W) from d[1]; k = d[8][7:0], stride
//   s = d[8][15:8], padding p = d[8][23:16]; output Ho x Wo = ((H + 2p - k) /
//   s + 1) x ((W + 2p - k) / s + 1) per channel at d[3] (planar), each the
//   maximum of its k x k window; padding never wins (a window with no input
//   pixel gives -128, as the model's -129 clipped).
//   Per channel and output row the k input rows y s - p + dy (those inside
//   the input) are read into the row memory; per strip of 32 output pixels,
//   per row: a 4-word window (128 bytes) read, then one compare of all 32
//   lanes per dx; the strip is the next 32-byte chunk of the output row's
//   write.
//   Errors (err_o with done_o, nothing written): k or s 0, s > 2 (the
//   window covers stride 1 and 2; the compiled programs use 1), k > K_MAX,
//   W > W_MAX, an empty output (H + 2p < k or W + 2p < k). The model needs
//   s >= 1 as well.
//   Parameters: W_MAX (input row bytes, multiple of 32), K_MAX (window).
//   Clock - clk. Reset - synchronous active low rst_n. Clock-domain
//   crossings - none.
// Date: 2026-10-26
module npu_pool #(
  parameter int W_MAX = 2048,                    // longest input row
  parameter int K_MAX = 7                        // largest window
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
  localparam int RW  = W_MAX / 32;               // words per row slot
  localparam int RAW = $clog2(K_MAX * RW);
  localparam int KB  = (K_MAX > 1) ? $clog2(K_MAX) : 1;
  if (W_MAX < 32 || W_MAX % 32 != 0 || K_MAX < 1) begin : g_bad
    $error("npu_pool: W_MAX a multiple of 32, K_MAX >= 1");
  end

  function automatic logic [31:0] dw(input int k);
    dw = d_i[32*k +: 32];
  endfunction

  typedef enum logic [3:0] {S_IDLE, S_ROW, S_ROWRD, S_WREQ, S_FETCH, S_CMP, S_EMIT, S_WEND, S_DONE} state_e;
  state_e st;
  logic rd_in_q;                                 // the read word of the clock before was inside the row
  logic [31:0]  src, dst, c, ci;
  logic [15:0]  h, w, ho, wo, y;
  logic [7:0]   k, s, p;
  logic [7:0]   dy, dx;                          // the row being read / compared, the tap
  logic [K_MAX-1:0] rvalid;                      // input row dy inside the input
  logic [15:0]  x0;                              // the strip's first output pixel
  logic [2:0]   fw;                              // window word being read (0 .. 4)
  logic [255:0] win [4];                         // the window: 4 words of the row
  logic signed [8:0]  acc [32];                  // lane maxima (-129: none yet)
  logic         rq_rd, rq_wr, err;
  logic [$clog2(RW):0] rk;                       // read chunk index
  logic [255:0] rm [K_MAX * RW];                 // the row memory: K_MAX rows
  logic [255:0] rm_q;

  // the window's first word: floor((x0 s - p) / 32), and its byte position
  wire signed [16:0] first = 17'($signed({1'b0, x0}) * $signed({9'd0, s})) - 17'($signed({1'b0, p}));
  wire signed [16:0] wfirst = first >>> 5;       // word (floor)
  wire signed [16:0] rd_word = wfirst + 17'($signed({14'd0, fw}));
  wire        rd_in = rd_word >= 0 && rd_word < 17'(RW);
  // read address: slot dy, word rd_word
  wire [RAW-1:0] rm_addr = RAW'(32'(dy) * 32'(RW) + 32'(rd_word[15:0]));
  // the output size: span / s as a shift (only stride 1 and 2 are accepted - no divider)
  wire        s_two = d_i[32*8+8 +: 8] == 8'd2;
  wire [31:0] ho_sp = 32'(d_i[32*5+16 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) - 32'(d_i[32*8+0 +: 8]);
  wire [31:0] wo_sp = 32'(d_i[32*5+0 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) - 32'(d_i[32*8+0 +: 8]);

  always_ff @(posedge clk) begin
    rm_q <= rm[rm_addr];
    if (st == S_ROWRD && dma.rd_valid && dma.rd_rdy) rm[RAW'(32'(dy) * 32'(RW) + 32'(rk))] <= dma.rd_data;
  end

  // the DMA
  assign dma.rd_req = rq_rd;
  assign dma.rd_addr = src + (ci * 32'(h) + 32'(y) * 32'(s) - 32'(p) + 32'(dy)) * 32'(w);
  assign dma.rd_len = {16'd0, w};
  assign dma.rd_rdy = st == S_ROWRD;
  assign dma.wr_req = rq_wr;
  assign dma.wr_addr = dst + (ci * 32'(ho) + 32'(y)) * 32'(wo);
  assign dma.wr_len = {16'd0, wo};
  assign dma.wr_valid = st == S_EMIT;
  wire [15:0] left = wo - x0;
  assign dma.wr_cnt = (left >= 16'd32) ? 6'd32 : 6'(left);
  always_comb begin
    for (int i = 0; i < 32; i++)
      dma.wr_data[8*i +: 8] = (acc[i] < -9'sd128) ? 8'h80 : acc[i][7:0];
  end

  // input row y s - p + dy inside the input
  wire signed [31:0] iy = $signed(32'(y) * 32'(s)) - $signed(32'(p)) + $signed(32'(dy));
  wire               iy_in = iy >= 0 && iy < $signed(32'(h));
  // compare lane i with tap dx: byte x0 s - p + dx + i s of the row, if inside it
  logic signed [8:0]  tap [32];
  logic [31:0]        tvalid;
  logic signed [16:0] pos [32], rel [32];
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      pos[i] = first + 17'($signed({9'd0, dx})) + 17'(i) * 17'($signed({9'd0, s}));
      rel[i] = pos[i] - (wfirst <<< 5);
      tvalid[i] = pos[i] >= 0 && pos[i] < 17'($signed({1'b0, w})) && rel[i] >= 0 && rel[i] < 17'sd128;
      tap[i] = 9'($signed(win[rel[i][6:5]][8*rel[i][4:0] +: 8]));
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= S_IDLE;
      src <= '0;
      dst <= '0;
      c <= '0;
      ci <= '0;
      h <= '0;
      w <= '0;
      ho <= '0;
      wo <= '0;
      y <= '0;
      k <= '0;
      s <= '0;
      p <= '0;
      dy <= '0;
      dx <= '0;
      rvalid <= '0;
      x0 <= '0;
      fw <= '0;
      for (int i = 0; i < 4; i++) win[i] <= '0;
      for (int i = 0; i < 32; i++) acc[i] <= -9'sd129;
      rq_rd <= 1'b0;
      rq_wr <= 1'b0;
      err <= 1'b0;
      rk <= '0;
    end else begin
      if (rq_rd && dma.rd_ready) rq_rd <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      unique case (st)
        S_IDLE: if (start_i) begin
          src <= dw(1);
          dst <= dw(3);
          c <= dw(4);
          ci <= '0;
          h <= d_i[32*5+16 +: 16];
          w <= d_i[32*5+0 +: 16];
          k <= d_i[32*8+0 +: 8];
          s <= d_i[32*8+8 +: 8];
          p <= d_i[32*8+16 +: 8];
          y <= '0;
          err <= 1'b0;
          if (d_i[32*8+0 +: 8] == '0 || d_i[32*8+8 +: 8] == '0 || d_i[32*8+8 +: 8] > 8'd2 || 32'(d_i[32*8+0 +: 8]) > 32'(K_MAX) ||
              32'(d_i[32*5+0 +: 16]) > 32'(W_MAX) ||
              32'(d_i[32*5+16 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) < 32'(d_i[32*8+0 +: 8]) ||
              32'(d_i[32*5+0 +: 16]) + 2 * 32'(d_i[32*8+16 +: 8]) < 32'(d_i[32*8+0 +: 8])) begin
            err <= 1'b1;
            st <= S_DONE;
          end else begin
            ho <= 16'((s_two ? ho_sp >> 1 : ho_sp) + 32'd1);
            wo <= 16'((s_two ? wo_sp >> 1 : wo_sp) + 32'd1);
            if (dw(4) == '0 || d_i[32*5+16 +: 16] == '0 || d_i[32*5+0 +: 16] == '0) st <= S_DONE;
            else st <= S_ROW;
            dy <= '0;
          end
        end
        // the k input rows of output row y
        S_ROW: begin
          if (dy == k) begin
            rq_wr <= 1'b1;
            x0 <= '0;
            st <= S_WREQ;
          end else begin
            rvalid[KB'(dy)] <= iy_in;
            if (iy_in) begin
              rq_rd <= 1'b1;
              rk <= '0;
              st <= S_ROWRD;
            end else begin
              dy <= dy + 8'd1;
            end
          end
        end
        S_ROWRD: if (dma.rd_valid) begin
          rk <= rk + 1'b1;
          if (dma.rd_last) begin
            dy <= dy + 8'd1;
            st <= S_ROW;
          end
        end
        S_WREQ: if (!rq_wr) begin                // the output row's write taken: strips
          for (int i = 0; i < 32; i++) acc[i] <= -9'sd129;
          dy <= '0;
          fw <= '0;
          st <= S_FETCH;
        end
        // per row dy: the 4 window words (rm_q one clock after its address), then the k taps
        S_FETCH: begin
          if (dy == k) begin
            st <= S_EMIT;
          end else if (!rvalid[KB'(dy)]) begin
            dy <= dy + 8'd1;
          end else begin
            if (fw != 3'd0) win[2'(fw - 3'd1)] <= rd_in_q ? rm_q : '0;
            if (fw == 3'd4) begin
              dx <= '0;
              st <= S_CMP;
            end
            fw <= fw + 3'd1;
          end
        end
        S_CMP: begin
          for (int i = 0; i < 32; i++)
            if (tvalid[i] && tap[i] > acc[i]) acc[i] <= tap[i];
          if (dx + 8'd1 == k) begin
            dy <= dy + 8'd1;
            fw <= '0;
            st <= S_FETCH;
          end
          dx <= dx + 8'd1;
        end
        S_EMIT: if (dma.wr_rdy) begin
          if (32'(x0) + 32 >= 32'(wo)) begin
            st <= S_WEND;
          end else begin
            x0 <= x0 + 16'd32;
            for (int i = 0; i < 32; i++) acc[i] <= -9'sd129;
            dy <= '0;
            fw <= '0;
            st <= S_FETCH;
          end
        end
        S_WEND: if (dma.wr_done) begin
          dy <= '0;
          if (y + 16'd1 < ho) begin
            y <= y + 16'd1;
            st <= S_ROW;
          end else if (ci + 32'd1 < c) begin
            ci <= ci + 32'd1;
            y <= '0;
            st <= S_ROW;
          end else begin
            st <= S_DONE;
          end
        end
        S_DONE: st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
  // the read word of the clock before was inside the row
  always_ff @(posedge clk) begin
    if (!rst_n) rd_in_q <= 1'b0;
    else rd_in_q <= rd_in;
  end
  assign done_o = st == S_DONE;
  assign err_o = st == S_DONE && err;
  wire unused_ok = &{1'b0, d_i, 1'b0};
endmodule
