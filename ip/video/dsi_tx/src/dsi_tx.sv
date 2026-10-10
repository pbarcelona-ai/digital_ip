// ***************
// Filename: dsi_tx.sv
// Author: FPGA Cores 4 U
// Description: MIPI DSI host transmitter, video mode with sync events.
//   Version 1.0.0. Drives a MIPI DSI display panel through a D-PHY (PPI
//   style, see mipi_tx_engine; the analog D-PHY is vendor IP).
//   Video - timed video on the pixel clock (rgb_i {B, G, R}, de_i, hs_i,
//   vs_i as driven to a display). At every hsync leading edge one DSI line
//   starts: a Vertical Sync Start packet (0x01) on the line where vsync
//   becomes active, a Horizontal Sync Start packet (0x21) on all others,
//   then sync_gap_i byte clocks of LP (blanking), then - if a video line was
//   received since the previous hsync - its RGB888 packed pixel stream
//   (0x3E, bytes R, G, B per pixel), then LP until the next line. Pixel
//   data therefore trails the sync events by exactly one line, keeping the
//   panel timing (VSA / VBP / VFP / HSA / HBP / HFP) of the timing
//   generator. eotp_i appends an End of Transmission packet to every
//   burst. Virtual channel vc_i. A line needs (width x 3 + 12) / NLANES
//   byte clocks plus the LP transitions; lines that do not fit are dropped
//   (line_drop_o).
//   Commands - for panel initialisation, while video_en_i is low: write the
//   payload bytes of a long command with cmd_byte_wr_i / cmd_byte_i, then
//   cmd_wr_i with cmd_i = {long, data type, data / word count}; e.g.
//   {0, 0x05, 0x0011} DCS short write "exit sleep", {0, 0x15, 0x0036}
//   with parameter in [15:8], {1, 0x39, n} DCS long write of n bytes. They
//   are sent in HS mode, in order, each in its own burst. Panels that only
//   accept commands in LP escape mode need the PHY's escape-mode path.
//   Clocks - pclk (video, commands), bclk (D-PHY byte clock). Resets -
//   synchronous per domain, active low.
// Date: 2026-10-02
module dsi_tx #(
  parameter int NLANES = 2,
  parameter int MAX_W  = 2048
) (
  // Pixel side
  input  logic                  pclk,
  input  logic                  prst_n,
  input  logic                  video_en_i,
  input  logic                  hs_pol_i,
  input  logic                  vs_pol_i,
  input  logic [23:0]           rgb_i,
  input  logic                  de_i,
  input  logic                  hs_i,
  input  logic                  vs_i,
  input  logic                  cmd_wr_i,
  input  logic [24:0]           cmd_i,           // {long, data type, data / word count}
  input  logic                  cmd_byte_wr_i,
  input  logic [7:0]            cmd_byte_i,
  output logic                  line_drop_o,
  // Byte side
  input  logic                  bclk,
  input  logic                  brst_n,
  input  logic [1:0]            vc_i,
  input  logic                  eotp_i,
  input  logic [15:0]           sync_gap_i,      // LP clocks after a sync packet
  input  logic [15:0]           line_gap_i,      // LP clocks after a pixel packet
  output logic [NLANES*8-1:0]   lane_data_o,
  output logic [NLANES-1:0]     lane_valid_o,
  output logic                  hs_req_o,
  input  logic                  tx_ready_i,
  output logic                  cmd_busy_o,      // byte clock: commands queued or being sent
  output logic                  underflow_o
);
  localparam int AW = $clog2(MAX_W / 2);
  logic lb_buf, lb_done;
  logic [AW-1:0] lb_addr;
  logic [47:0] lb_data;

  // ================================================================ pixel side
  logic de_q, hs_q, vs_q, pend;
  logic pbuf;
  logic [15:0] pwidth;
  wire  hs_lead  = (hs_i == hs_pol_i) && (hs_q != hs_pol_i);
  wire  vs_act   = (vs_i == vs_pol_i);
  wire  vs_lead  = vs_act && (vs_q != vs_pol_i);
  wire  line_end = de_q && !de_i;
  logic lr, lbuf;
  logic [15:0] lwidth;
  mipi_line_buf #(.MAX_W(MAX_W)) u_lb (
    .pclk,
    .prst_n,
    .px_i(rgb_i),
    .px_valid_i(de_i && video_en_i),
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

  // Line events at each hsync leading edge: {VSS, pixels pending, buffer, width}
  logic [18:0] ev_w;
  always_ff @(posedge pclk) begin
    if (!prst_n) begin
      de_q <= 1'b0;
      hs_q <= 1'b0;
      vs_q <= 1'b0;
      pend <= 1'b0;
      pbuf <= 1'b0;
      pwidth <= '0;
    end
    else begin
      de_q <= de_i;
      hs_q <= hs_i;
      vs_q <= vs_i;
      if (lr) begin
        pend <= 1'b1;
        pbuf <= lbuf;
        pwidth <= lwidth;
      end
      else if (hs_lead) pend <= 1'b0;
    end
  end
  // vsync is aligned with the hsync leading edge (CEA-861); vs_lead or vsync
  // already active at an hsync edge after an inactive line both mean VSS
  logic vs_line_q;                                  // vsync was active on the previous line
  always_ff @(posedge pclk)
    if (!prst_n) vs_line_q <= 1'b0;
    else if (hs_lead) vs_line_q <= vs_act;
  assign ev_w = {vs_act && !vs_line_q, pend, pbuf, pwidth};
  logic [18:0] ev;
  logic ev_v, ev_r;
  async_fifo #(
    .DATA_W(19),
    .DEPTH(16)
  ) u_ev (
    .wclk(pclk),
    .wrst_n(prst_n),
    .wdata(ev_w),
    .wvalid(hs_lead && video_en_i),
    .wready(),
    .wlevel_o(),
    .rclk(bclk),
    .rrst_n(brst_n),
    .rdata(ev),
    .rvalid(ev_v),
    .rready(ev_r)
  );

  // Commands and their payload bytes
  logic [24:0] cq;
  logic cq_v, cq_r;
  logic [7:0] pb;
  logic pb_v, pb_r;
  async_fifo #(
    .DATA_W(25),
    .DEPTH(16)
  ) u_cmd (
    .wclk(pclk),
    .wrst_n(prst_n),
    .wdata(cmd_i),
    .wvalid(cmd_wr_i),
    .wready(),
    .wlevel_o(),
    .rclk(bclk),
    .rrst_n(brst_n),
    .rdata(cq),
    .rvalid(cq_v),
    .rready(cq_r)
  );
  async_fifo #(
    .DATA_W(8),
    .DEPTH(256)
  ) u_pay (
    .wclk(pclk),
    .wrst_n(prst_n),
    .wdata(cmd_byte_i),
    .wvalid(cmd_byte_wr_i),
    .wready(),
    .wlevel_o(),
    .rclk(bclk),
    .rrst_n(brst_n),
    .rdata(pb),
    .rvalid(pb_v),
    .rready(pb_r)
  );
  (* async_reg = "true" *) logic ven_s1, ven_s2;
  always_ff @(posedge bclk) begin
    ven_s1 <= video_en_i;
    ven_s2 <= ven_s1;
  end

  // ================================================================ byte side
  logic [45:0] cmd;
  logic cmd_v, cmd_r;
  function automatic logic [45:0] mk(input logic [1:0] t, input logic [7:0] di, input logic [15:0] d,
                                     input logic [1:0] f, input logic b, input logic [15:0] g, input logic e);
    mk = {e, g, b, f, d, di, t};
  endfunction
  wire        e_vss = ev[18], e_pix = ev[17], e_buf = ev[16];
  wire [15:0] e_w   = ev[15:0];
  logic sync_sent;                                   // the sync packet of this event is out
  always_comb begin
    cmd_v = 1'b0;
    ev_r = 1'b0;
    cq_r = 1'b0;
    cmd = '0;
    if (ev_v) begin                                  // video has priority
      cmd_v = 1'b1;
      if (!sync_sent) cmd = mk(2'd0, {vc_i, e_vss ? 6'h01 : 6'h21}, 16'h0000, 2'd0, 1'b0, sync_gap_i, eotp_i);
      else            cmd = mk(2'd1, {vc_i, 6'h3E}, e_w, 2'd1, e_buf, line_gap_i, eotp_i);
      ev_r = cmd_r && (sync_sent || !e_pix);
    end else if (cq_v && !ven_s2) begin              // commands only while video is off
      cmd_v = 1'b1;
      cmd = mk(cq[24] ? 2'd2 : 2'd0, {vc_i, cq[21:16]}, cq[15:0], 2'd0, 1'b0, 16'd8, eotp_i);
      cq_r = cmd_r;
    end
  end
  always_ff @(posedge bclk) begin
    if (!brst_n) sync_sent <= 1'b0;
    else if (ev_v && cmd_r) sync_sent <= !sync_sent && e_pix;
  end
  logic eng_busy;
  assign cmd_busy_o = cq_v || (eng_busy && !ev_v);

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
    .pl_data_i(pb),
    .pl_valid_i(pb_v),
    .pl_ready_o(pb_r),
    .lane_data_o,
    .lane_valid_o,
    .hs_req_o,
    .tx_ready_i,
    .busy_o(eng_busy),
    .underflow_o
  );
endmodule
