// ***************
// Filename: npu_fw.sv
// Author: FPGA Cores 4 U
// Description: Frame writer of the NPU (model/npu_model.py NpuTop.frame /
//   write_frame: the bytes written equal the model's). Version 1.0.1.
//   A passive tap (axis_if.monitor) on the RGB888 video ({B, G, R}, R in
//   the LSBs; tuser start of frame, tlast end of line): with en_i (CTRL.EN
//   and CTRL.WRITE) and no run active (busy_i) at a frame's first pixel, the
//   frame is taken: line y at addr_i + y stride_i, 3 W bytes (R, G, B per
//   pixel); the lines go through a ring of NLB line buffers, each written
//   by the DMA while the next ones fill. W comes from the first line (its
//   tlast): a frame whose lines do not fit the stride (stride < 3 W) or the
//   buffer (W > W_MAX) is not written, as the model skips it. The frame ends
//   after height_i lines (FRAME_SIZE.HEIGHT) or at the next start of frame;
//   frame_o pulses once its last line is in memory, with written_o
//   (STATUS.FRAME). A frame not written - its lines too long for the stride
//   or the buffer, or a line ending while NLB lines still wait for their
//   write (the DMA that far behind the video) - gives frame_o alone, at
//   once: the model runs AUTO after every frame, written or not.
//   Parameters: W_MAX (pixels per line; 3 W_MAX a multiple of 32), NLB (line
//   buffers, a power of two >= 2).
//   Clock - clk (the video's and the NPU's). Reset - synchronous active low
//   rst_n. Clock-domain crossings - none.
// Date: 2026-10-26
module npu_fw #(
  parameter int W_MAX = 2048,                    // pixels per line
  parameter int NLB   = 4                        // line buffers
) (
  input  logic          clk,                     // clock
  input  logic          rst_n,                   // synchronous, active low
  // s_axis: axis_if.monitor (ip/shared/src/interfaces/axis_if.sv), DATA_W = 24
  axis_if.monitor       s_axis,
  input  logic          en_i,                    // CTRL.EN and CTRL.WRITE
  input  logic          busy_i,                  // a run active: no frame taken
  input  logic [31:0]   addr_i,                  // FRAME_ADDR
  input  logic [15:0]   stride_i,                // FRAME_STRIDE
  input  logic [15:0]   height_i,                // FRAME_SIZE.HEIGHT
  output logic          active_o,                // a frame being written (the DMA in use)
  output logic          frame_o,                 // one clock: a frame taken has ended (AUTO)
  output logic          written_o,               // with frame_o: the frame is in memory (STATUS.FRAME)
  // dma: npu_dma_if.cli (src/npu_dma_if.sv)
  npu_dma_if.cli        dma
);
  localparam int LB = 3 * W_MAX;                 // line bytes
  localparam int QB = $clog2(NLB);
  localparam int LWW = LB / 32;                  // 32-byte words per line buffer
  localparam int WWA = $clog2(LWW);              // a word's address in its buffer (buffer b at b << WWA)
  if (LB % 32 != 0 || NLB < 2 || (NLB & (NLB - 1)) != 0) begin : g_bad
    $error("npu_fw: 3 W_MAX a multiple of 32, NLB a power of two >= 2");
  end

  logic         cap, bad;                        // capturing a frame; dropping it
  logic [QB-1:0] wbuf;                           // the buffer filling
  logic [15:0]  x, ylines;                       // pixel in the line; lines completed
  logic [31:0]  w3;                              // bytes per line (from the first line)
  logic [QB:0]  qn;                              // lines waiting for their write (the oldest at rbuf)
  logic [QB-1:0] rbuf;                           // the buffer being written
  logic [15:0]  ly [NLB];                        // each buffer's line number
  logic [NLB-1:0] llast;                         // each buffer's line the frame's last
  logic [10:0]  kc;
  logic         rq_wr, wact, fin;
  wire          beat = s_axis.tvalid && s_axis.tready;
  wire          sof = beat && s_axis.tuser;
  wire          take = sof && en_i && !busy_i;  // a frame taken at its first pixel

  // the line buffers (a ring): 32 byte lanes, lane i holding the bytes at positions i mod 32 of each buffer's
  // words; a pixel's 3 bytes land in 3 different lanes, a DMA chunk reads every lane at one word (one write
  // and one read port per lane: block / distributed RAM)
  wire [31:0] lpos = 3 * 32'(sof ? 16'd0 : x);     // a frame's first pixel: position 0 of the next buffer
  wire        lb_we = beat && (cap || take) && lpos + 2 < LB;
  localparam int LDA = QB + WWA;                 // lane memory address bits
  logic [31:0][LDA-1:0] lb_wa, lb_ra;
  logic [31:0][7:0]     lb_wd, lb_rd;            // lb_rd: the chunk's bytes (word kc of buffer rbuf)
  logic [31:0]          lb_wl;
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      lb_wl[i] = 1'b0;
      lb_wa[i] = '0;
      lb_wd[i] = '0;
      for (int b = 0; b < 3; b++)                // the pixel's byte b in lane (lpos + b) mod 32
        if (5'(lpos + 32'(b)) == 5'(i)) begin
          lb_wl[i] = lb_we;
          lb_wa[i] = {wbuf, WWA'((lpos + 32'(b)) >> 5)};
          lb_wd[i] = s_axis.tdata[8*b +: 8];
        end
      lb_ra[i] = {rbuf, WWA'(kc)};
    end
  end
  npu_lane_mem #(
    .LANES(32),
    .DEPTH(NLB << WWA),
    .W(8)
  ) u_lb (
    .clk,
    .we_i(lb_wl),
    .waddr_i(lb_wa),
    .wdata_i(lb_wd),
    .raddr_i(lb_ra),
    .rdata_o(lb_rd)
  );

  // a line ends: its width (first line), whether it is written, whether it is the frame's last
  wire        eol = beat && s_axis.tlast && (sof ? take : cap);
  wire [31:0] lw3 = (ylines == '0 || sof) ? (sof ? 32'd1 : 32'(x) + 32'd1) * 3 : w3;
  wire        fits = 32'(stride_i) >= lw3 && lw3 <= 32'(LB);
  wire [15:0] lnum = sof ? 16'd0 : ylines;
  wire        wdone = wact && dma.wr_done;

  // DMA: the oldest waiting line
  assign dma.rd_req = 1'b0;
  assign dma.rd_addr = '0;
  assign dma.rd_len = 32'd1;
  assign dma.rd_rdy = 1'b0;
  assign dma.wr_req = rq_wr;
  assign dma.wr_addr = addr_i + 32'(ly[rbuf]) * 32'(stride_i);
  assign dma.wr_len = w3;
  assign dma.wr_valid = wact && !rq_wr && (32'(kc) << 5) < w3;
  wire [31:0] wleft = w3 - (32'(kc) << 5);
  assign dma.wr_cnt = (wleft >= 32'd32) ? 6'd32 : 6'(wleft);
  always_comb begin
    for (int i = 0; i < 32; i++) dma.wr_data[8*i +: 8] = lb_rd[i];
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cap <= 1'b0;
      bad <= 1'b0;
      wbuf <= '0;
      x <= '0;
      ylines <= '0;
      w3 <= '0;
      qn <= '0;
      rbuf <= '0;
      for (int i = 0; i < NLB; i++) ly[i] <= '0;
      llast <= '0;
      kc <= '0;
      rq_wr <= 1'b0;
      wact <= 1'b0;
      fin <= 1'b0;
      frame_o <= 1'b0;
      written_o <= 1'b0;
    end else begin
      frame_o <= 1'b0;
      written_o <= 1'b0;
      if (rq_wr && dma.wr_ready) rq_wr <= 1'b0;
      // capture
      if (sof) begin
        if (cap && !bad && ylines != '0) fin <= 1'b1;   // the previous frame ends here (fewer lines than HEIGHT)
        cap <= take;
        bad <= 1'b0;
        ylines <= '0;
        x <= 16'd1;
      end else if (beat && cap) begin
        x <= x + 16'd1;
      end
      if (eol) begin
        x <= '0;
        ylines <= lnum + 16'd1;
        if (lnum == '0) w3 <= lw3;
        if (!fits || 32'(qn) + 32'(wact) >= NLB) begin   // not written / the DMA too far behind
          cap <= 1'b0;
          bad <= 1'b1;
          frame_o <= !bad;                              // the frame ends for AUTO, not written
        end else begin
          ly[wbuf] <= lnum;
          llast[wbuf] <= lnum + 16'd1 == height_i;
          wbuf <= wbuf + 1'b1;
          if (lnum + 16'd1 == height_i) cap <= 1'b0;    // the frame's last line
        end
      end
      // the line writes, oldest first
      if (!wact && qn != '0) begin
        wact <= 1'b1;
        kc <= '0;
        rq_wr <= 1'b1;
      end
      if (wact && dma.wr_valid && dma.wr_rdy) kc <= kc + 1'b1;
      if (wdone) begin
        wact <= 1'b0;
        rbuf <= rbuf + 1'b1;
        if (llast[rbuf] && !bad) begin
          frame_o <= 1'b1;
          written_o <= 1'b1;
        end
      end
      qn <= qn + (QB+1)'(eol && fits && 32'(qn) + 32'(wact) < NLB) - (QB+1)'(!wact && qn != '0);
      if (fin && qn == '0 && !wact) begin             // ended by the next frame's start
        fin <= 1'b0;
        frame_o <= 1'b1;
        written_o <= 1'b1;
      end
    end
  end
  assign active_o = cap || qn != '0 || wact || fin;
  wire unused_ok = &{1'b0, s_axis.tkeep, 1'b0};
endmodule
