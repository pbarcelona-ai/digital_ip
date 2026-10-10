// ***************
// Filename: csi2_tx.sv
// Author: FPGA Cores 4 U
// Description: MIPI CSI-2 transmitter: video in, CSI-2 packets out on a D-PHY
//   (PPI style, see mipi_tx_engine). Version 1.0.0. Makes the pipeline output
//   look like a camera to a downstream processor.
//   Input - timed video on the pixel clock (rgb_i, de_i, vs_i, as driven to a
//   display): a frame starts at the vsync leading edge (vs_pol_i = active
//   level), each de run is a line. Pixels {B, G, R}, or {Cb, Y, Cr} for YUV.
//   Output per frame: Frame Start (data = frame number, 1..65535), one long
//   packet per line - RGB888 (data type 0x24, bytes B, G, R) or YUV422 8-bit
//   (0x1E, bytes U, Y0, V, Y1, chroma averaged over the pixel pair; even
//   widths only) - and Frame End at the next vsync, each packet in its own
//   HS burst followed by lp_gap_i byte clocks of LP state. Virtual channel
//   vc_i. Lines are buffered (mipi_line_buf): the link must carry a line
//   (width x 3 or 2 bytes / NLANES byte clocks plus about 40 clocks of
//   overhead) within a line time; otherwise lines are dropped and
//   line_drop_o pulses. Config is quasi-static (change it between frames,
//   or with enable_i low). Clocks - pclk, bclk (D-PHY byte clock). Resets -
//   synchronous per domain, active low.
// Date: 2026-10-02
module csi2_tx #(
  parameter int NLANES = 2,
  parameter int MAX_W  = 2048
) (
  // Pixel side
  input  logic                  pclk,
  input  logic                  prst_n,
  input  logic                  enable_i,
  input  logic                  vs_pol_i,
  input  logic [23:0]           rgb_i,
  input  logic                  de_i,
  input  logic                  vs_i,
  output logic                  line_drop_o,
  output logic [31:0]           frames_o,
  // Byte side
  input  logic                  bclk,
  input  logic                  brst_n,
  input  logic [1:0]            vc_i,
  input  logic                  yuv422_i,         // 0 RGB888, 1 YUV422 8-bit
  input  logic [15:0]           lp_gap_i,
  output logic [NLANES*8-1:0]   lane_data_o,
  output logic [NLANES-1:0]     lane_valid_o,
  output logic                  hs_req_o,
  input  logic                  tx_ready_i,
  output logic                  underflow_o
);
  localparam int AW = $clog2(MAX_W / 2);

  // Line buffer read side (byte clock), used by the engine
  logic lb_buf, lb_done;
  logic [AW-1:0] lb_addr;
  logic [47:0] lb_data;

  // ================================================================ pixel side
  logic de_q, vs_q, frame_open, sof_line, line_sof;
  logic [15:0] fnum;
  wire  vs_lead  = (vs_i == vs_pol_i) && (vs_q != vs_pol_i);
  wire  line_end = de_q && !de_i;
  logic lr;
  logic lbuf;
  logic [15:0] lwidth;
  logic [35:0] ev_w;
  logic ev_wv, ev_wr;

  mipi_line_buf #(.MAX_W(MAX_W)) u_lb (
    .pclk,
    .prst_n,
    .px_i(rgb_i),
    .px_valid_i(de_i && enable_i && frame_open),
    .line_end_i(line_end),
    .line_ready_o(lr),
    .line_buf_o(lbuf),
    .line_width_o(lwidth),
    .line_drop_o(line_drop_o),
    .bclk,
    .brst_n,
    .rd_buf_i(lb_buf),
    .rd_addr_i(lb_addr),
    .rd_data_o(lb_data),
    .done_i(lb_done)
  );

  // Events: {type (0 line, 1 frame end), sof, buffer, width, frame number}
  always_comb begin
    ev_wv = 1'b0;
    ev_w = '0;
    if (lr) begin
      ev_wv = 1'b1;
      ev_w = {2'd0, line_sof, lbuf, lwidth, fnum};
    end
    else if (vs_lead && frame_open) begin
      ev_wv = 1'b1;
      ev_w = {2'd1, 1'b0, 1'b0, 16'd0, fnum};
    end
  end

  always_ff @(posedge pclk) begin
    if (!prst_n) begin
      de_q <= 1'b0;
      vs_q <= 1'b0;
      frame_open <= 1'b0;
      sof_line <= 1'b0;
      line_sof <= 1'b0;
      fnum <= 16'd0;
      frames_o <= '0;
    end else begin
      de_q <= de_i;
      vs_q <= vs_i;
      if (de_i && !de_q) begin
        line_sof <= sof_line;
        sof_line <= 1'b0;
      end
      if (vs_lead) begin
        // the event above (frame end) is written in this clock; then a new frame
        frame_open <= enable_i;
        sof_line <= enable_i;
        if (enable_i) begin
          fnum <= (fnum == 16'hFFFF) ? 16'd1 : fnum + 1'b1;
          frames_o <= frames_o + 1'b1;
        end
      end
    end
  end

  // Line events are rare compared to the clocks, so a frame-end event in the
  // same clock as a line event cannot happen (a line ends before vsync).
  logic [35:0] ev;
  logic ev_v, ev_r;
  async_fifo #(
    .DATA_W(36),
    .DEPTH(16)
  ) u_ev (
    .wclk(pclk),
    .wrst_n(prst_n),
    .wdata(ev_w),
    .wvalid(ev_wv),
    .wready(ev_wr),
    .wlevel_o(),
    .rclk(bclk),
    .rrst_n(brst_n),
    .rdata(ev),
    .rvalid(ev_v),
    .rready(ev_r)
  );

  // ================================================================ byte side
  logic [45:0] cmd;
  logic cmd_v, cmd_r;
  // Packet command {eotp, gap, buf, fmt, data, DI, type}
  function automatic logic [45:0] mk(input logic [1:0] t, input logic [7:0] di, input logic [15:0] d,
                                     input logic [1:0] f, input logic b, input logic [15:0] g);
    mk = {1'b0, g, b, f, d, di, t};
  endfunction

  wire [1:0]  e_type = ev[35:34];
  wire        e_sof  = ev[33], e_buf = ev[32];
  wire [15:0] e_w    = ev[31:16], e_fn = ev[15:0];
  logic fs_done;                                  // FS of this event already issued
  always_comb begin
    cmd_v = ev_v;
    ev_r = 1'b0;
    if (e_type == 2'd1)            cmd = mk(2'd0, {vc_i, 6'h01}, e_fn, 2'd0, 1'b0, lp_gap_i);               // Frame End
    else if (e_sof && !fs_done)    cmd = mk(2'd0, {vc_i, 6'h00}, e_fn, 2'd0, 1'b0, lp_gap_i);               // Frame Start
    else                           cmd = mk(2'd1, {vc_i, yuv422_i ? 6'h1E : 6'h24}, e_w,
                                            yuv422_i ? 2'd2 : 2'd0, e_buf, lp_gap_i);                       // line
    if (cmd_r && ev_v && !(e_type == 2'd0 && e_sof && !fs_done)) ev_r = 1'b1;                               // event done
  end
  always_ff @(posedge bclk) begin
    if (!brst_n) fs_done <= 1'b0;
    else if (cmd_r && ev_v) fs_done <= (e_type == 2'd0 && e_sof && !fs_done);
  end

  mipi_tx_engine #(
    .NLANES(NLANES),
    .MAX_W(MAX_W)
  ) u_eng (
    .clk(bclk),
    .rst_n(brst_n),
    .cmd_i(cmd),
    .cmd_valid_i(cmd_v),
    .cmd_ready_o(cmd_r),
    .lb_buf_o(lb_buf),
    .lb_addr_o(lb_addr),
    .lb_data_i(lb_data),
    .lb_done_o(lb_done),
    .pl_data_i(8'd0),
    .pl_valid_i(1'b0),
    .pl_ready_o(),
    .lane_data_o,
    .lane_valid_o,
    .hs_req_o,
    .tx_ready_i,
    .busy_o(),
    .underflow_o
  );
endmodule
