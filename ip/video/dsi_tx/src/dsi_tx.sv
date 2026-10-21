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
//   (line_drop_o; also when its event cannot be queued, e.g. with the byte
//   clock stopped). Long commands carry at most 64 payload bytes: a longer one
//   is rejected (cmd_err_o, its payload bytes are dropped); writes to a full
//   command / payload queue are lost and flagged (cmd_ovf_o / pay_ovf_o): at
//   most 16 queued commands and 256 queued payload bytes.
//   Commands - for panel initialisation, while video_en_i is low: write the
//   payload bytes of a long command with cmd_byte_wr_i / cmd_byte_i, then
//   cmd_wr_i with cmd_i = {long, data type, data / word count}; e.g.
//   {0, 0x05, 0x0011} DCS short write "exit sleep", {0, 0x15, 0x0036}
//   with parameter in [15:8], {1, 0x39, n} DCS long write of n bytes. They
//   are sent in HS mode, in order, each in its own burst. Panels that only
//   accept commands in LP escape mode need the PHY's escape-mode path.
//   Clocks - pclk (video, commands), bclk (D-PHY byte clock). Resets -
//   synchronous per domain, active low.
// Date: 2026-10-21
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
  // vid: vid_if.sink (ip/shared/src/interfaces/vid_if.sv), DATA_W = 24 {rgb_i=data de_i=de hs_i=hs vs_i=vs}
  vid_if.sink vid,
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
  // ppi: ppi_tx_if.link (ip/shared/src/interfaces/ppi_tx_if.sv), NLANES = NLANES {lane_data_o=lane_data lane_valid_o=lane_valid hs_req_o=hs_req tx_ready_i=tx_ready}
  ppi_tx_if.link ppi,
  output logic                  cmd_busy_o,      // byte clock: commands queued or being sent
  output logic                  underflow_o,
  output logic                  cmd_err_o,       // pulse (pclk): a long command over 64 payload bytes was rejected
  output logic                  cmd_ovf_o,       // pulse (pclk): DSI command written while its queue was full (lost)
  output logic                  pay_ovf_o        // pulse (pclk): payload byte written while its queue was full (lost)
);
  localparam int AW = $clog2(MAX_W / 2);
  logic lb_buf, lb_done;
  logic [AW-1:0] lb_addr;
  logic [47:0] lb_data;

  // ================================================================ pixel side
  logic de_q, hs_q, vs_q, pend;
  logic pbuf;
  logic [15:0] pwidth;
  wire  hs_lead  = (vid.hs == hs_pol_i) && (hs_q != hs_pol_i);
  wire  vs_act   = (vid.vs == vs_pol_i);
  wire  vs_lead  = vs_act && (vs_q != vs_pol_i);
  wire  line_end = de_q && !vid.de;
  logic lr, lbuf;
  logic [15:0] lwidth;
  // a line is only taken when its event can be queued and no earlier line is still waiting for one
  logic [4:0] ev_lvl;
  logic ev_wr, line_ok, lb_drop;
  wire  line_start = vid.de && !de_q;
  wire  ev_room = (ev_lvl <= 5'd14) && !pend;
  wire  px_ok = line_start ? ev_room : line_ok;
  mipi_line_buf #(.MAX_W(MAX_W)) u_lb (
    .pclk,
    .prst_n,
    .px_i(vid.data),
    .px_valid_i(vid.de && video_en_i && px_ok),
    .line_end_i(line_end),
    .line_ready_o(lr),
    .line_buf_o(lbuf),
    .line_width_o(lwidth),
    .line_drop_o(lb_drop),
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
      de_q <= vid.de;
      hs_q <= vid.hs;
      vs_q <= vid.vs;
      if (lr) begin
        pend <= 1'b1;
        pbuf <= lbuf;
        pwidth <= lwidth;
      end
      else if (hs_lead && ev_wr) pend <= 1'b0;      // kept until its event is queued
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
    .wready(ev_wr),
    .wlevel_o(ev_lvl),
    .rclk(bclk),
    .rrst_n(brst_n),
    .rdata(ev),
    .rvalid(ev_v),
    .rready(ev_r)
  );

  // Commands and their payload bytes
  logic [24:0] cq;                                // {[24] long, [23:22] not used (VC from vc_i), [21:16] type, [15:0]}
  logic [4:0] cq_level;                           // FIFO levels (not used)
  logic [8:0] pb_level;
  logic err_busy, err_drop;                       // not used: an error pulse per rejected command
  logic cq_wr, pb_wr;                               // command / payload queues not full (pclk)
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
    .wready(cq_wr),
    .wlevel_o(cq_level),
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
    .wready(pb_wr),
    .wlevel_o(pb_level),
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
  always_ff @(posedge pclk) begin
    if (!prst_n) line_ok <= 1'b0;
    else if (line_start) line_ok <= ev_room;
  end
  // dropped lines: line buffers full, no room for the event, or a sync event lost (FIFO full)
  assign line_drop_o = lb_drop || (line_start && video_en_i && !ev_room) || (hs_lead && video_en_i && !ev_wr);
  assign cmd_ovf_o = cmd_wr_i && !cq_wr;
  assign pay_ovf_o = cmd_byte_wr_i && !pb_wr;
  logic eng_err;
  pulse_sync u_err (
    .src_clk(bclk),
    .src_rst_n(brst_n),
    .pulse_i(eng_err),
    .busy_o(err_busy),
    .drop_o(err_drop),
    .dst_clk(pclk),
    .dst_rst_n(prst_n),
    .pulse_o(cmd_err_o)
  );

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
    .ppi(ppi),
    .busy_o(eng_busy),
    .underflow_o,
    .cmd_err_o(eng_err)
  );
  wire unused_ok = &{1'b0, vs_lead, cq[23:22], cq_level, pb_level, err_busy, err_drop, 1'b0};
endmodule
