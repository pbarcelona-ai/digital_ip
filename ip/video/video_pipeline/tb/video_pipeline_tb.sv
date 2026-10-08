// ***************
// Filename: video_pipeline_tb.sv
// Author: FPGA Cores 4 U
// Description: System testbench for video_pipeline: MIPI CSI-2 camera in,
//   HDMI / DVI out. A camera model mosaics a synthetic RGB scene into an
//   RGGB RAW10 image (with black level and two defective pixels) and streams
//   it continuously as CSI-2 frames on 2 D-PHY lanes (csi2_lane_driver).
//   The TMDS output is decoded by hdmi_sink_model. A bit-exact model of the
//   chain (black level, white balance, defect correction, demosaic, CCM,
//   gamma table, CSC, scaler) predicts every output pixel. Scenarios:
//     1. full ISP, HDMI, RGB out (CSC bypassed), gamma 2.2 table
//     2. full ISP, HDMI, YCbCr 4:4:4 BT.709 (AVI InfoFrame must follow)
//     3. everything bypassed, DVI: grey raw >> 2
//     4. a mixed bypass mask
//     5. scaler 1:1 and 2:1 (display 16x12), routed through scaler_bilinear
//     6. test pattern
//     7. a camera header bit error: corrected, image unchanged
//     8. the other outputs, same frame: LVDS (decoded OpenLDI VESA words),
//        MIPI CSI-2 TX (looped into a second csi2_rx) and MIPI DSI
//        (dsi_rx_model; an init command first, then VSS / HSS and pixel
//        packets), all compared with the model
//   The interfaces follow configuration.sv: excluded ones are not connected
//   and not checked. Scenarios 1-7 need the camera input and HDMI; without
//   the camera, scenario 8 checks every output against the test pattern.
//   BUILD_CFG must report the configuration. +quick runs scenario 8 only.
//   plus the status registers (CSI frames, ECC / CRC counters, defects
//   corrected, statistics against the model, lock). Prints TEST PASSED on
//   success.
// Date: 2026-10-01
`timescale 1ns/1ps
module video_pipeline_tb;
  localparam int W = 32, H = 24;
  int OW = W, OH = H;                                // display active size
  logic byte_clk = 0, pix_clk = 0, byte_rst_n = 0, pix_rst_n = 0;
  always #4 byte_clk = ~byte_clk;                  // 125 MHz D-PHY byte clock
  always #5 pix_clk = ~pix_clk;                    // 100 MHz pixel clock
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask
  initial begin #20ms; $display("ERROR: simulation timeout"); $display("TEST FAILED"); $finish; end

  // ---------------- DUT ----------------
  logic [15:0] ld; logic [1:0] lv;
  logic [14:0] s_axil_awaddr, s_axil_araddr; logic s_axil_awvalid, s_axil_awready, s_axil_wvalid, s_axil_wready;
  logic [31:0] s_axil_wdata, s_axil_rdata; logic [3:0] s_axil_wstrb; logic [1:0] s_axil_bresp, s_axil_rresp;
  logic s_axil_bvalid, s_axil_bready, s_axil_arvalid, s_axil_arready, s_axil_rvalid, s_axil_rready;
  logic [9:0] t0, t1, t2, tc; logic sdone;
  logic [27:0] lva, lvb; logic [6:0] lvc; logic lvs;
  logic [15:0] dsi_d, ctx_d; logic [1:0] dsi_v, ctx_v; logic dsi_req, ctx_req, dsi_rdy = 0, ctx_rdy = 0;
  video_pipeline #(.NLANES(2), .MAX_W(64), .CSI_FIFO(256), .OUT_FIFO(512)) dut (
`ifdef VP_CSI2_RX
    .byte_clk, .byte_rst_n, .lane_data_i(ld), .lane_valid_i(lv),
`endif
    .pix_clk, .pix_rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready, .s_axil_wdata, .s_axil_wstrb, .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp, .s_axil_bvalid, .s_axil_bready, .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata, .s_axil_rresp, .s_axil_rvalid, .s_axil_rready,
`ifdef VP_HDMI
    .tmds0_o(t0), .tmds1_o(t1), .tmds2_o(t2), .tmds_clk_o(tc),
`endif
`ifdef VP_LVDS
    .lvds_a_o(lva), .lvds_b_o(lvb), .lvds_clk_word_o(lvc), .lvds_stb_o(lvs),
`endif
`ifdef VP_MIPI_TX
    .tx_byte_clk(byte_clk), .tx_byte_rst_n(byte_rst_n),
`endif
`ifdef VP_DSI
    .dsi_lane_data_o(dsi_d), .dsi_lane_valid_o(dsi_v), .dsi_hs_req_o(dsi_req), .dsi_tx_ready_i(dsi_rdy),
`endif
`ifdef VP_CSI2_TX
    .csitx_lane_data_o(ctx_d), .csitx_lane_valid_o(ctx_v), .csitx_hs_req_o(ctx_req), .csitx_tx_ready_i(ctx_rdy),
`endif
    .stats_done_o(sdone));
  // Outputs of interfaces that are not built stay idle
`ifndef VP_HDMI
  assign t0 = 10'b1101010100; assign t1 = 10'b1101010100; assign t2 = 10'b1101010100; assign tc = '0;
`endif
`ifndef VP_LVDS
  assign lva = '0; assign lvb = '0; assign lvc = '0; assign lvs = 1'b0;
`endif
`ifndef VP_DSI
  assign dsi_d = '0; assign dsi_v = '0; assign dsi_req = 1'b0;
`endif
`ifndef VP_CSI2_TX
  assign ctx_d = '0; assign ctx_v = '0; assign ctx_req = 1'b0;
`endif
  // D-PHY models: fixed start-of-transmission time
  int dsi_sot = 0, ctx_sot = 0;
  always @(posedge byte_clk) begin
    if (!dsi_req) begin dsi_rdy <= 0; dsi_sot = 0; end else if (!dsi_rdy && ++dsi_sot == 6) dsi_rdy <= 1;
    if (!ctx_req) begin ctx_rdy <= 0; ctx_sot = 0; end else if (!ctx_rdy && ++ctx_sot == 6) ctx_rdy <= 1;
  end
  dsi_rx_model #(.NL(2)) dsi_rx (.clk(byte_clk), .lane_data(dsi_d), .lane_valid(dsi_v));
  // CSI-2 TX looped back into a receiver
  logic [15:0] cr_d; logic [1:0] cr_k; logic cr_l, cr_u, cr_v, cr_fs, cr_fe, cr_ln, cr_ec, cr_ee, cr_ce, cr_ov;
  csi2_rx #(.NLANES(2)) ctx_rx (.clk(byte_clk), .rst_n(byte_rst_n), .lane_data_i(ctx_d), .lane_valid_i(ctx_v), .vc_i(2'd2), .dt_i(6'h24),
    .m_axis_tdata(cr_d), .m_axis_tkeep(cr_k), .m_axis_tlast(cr_l), .m_axis_tuser(cr_u), .m_axis_tvalid(cr_v), .m_axis_tready(1'b1),
    .frame_start_o(cr_fs), .frame_end_o(cr_fe), .line_o(cr_ln), .ecc_corrected_o(cr_ec), .ecc_error_o(cr_ee), .crc_error_o(cr_ce), .overflow_o(cr_ov));
  byte unsigned ctx_line [H][3*W]; int ctx_y = 0, ctx_n = 0, ctx_frames = 0, ctx_err = 0;
  always @(posedge byte_clk) if (byte_rst_n) begin
    ctx_err += cr_ee + cr_ce;
    if (cr_fs) begin if (ctx_y == H) ctx_frames++; ctx_y = 0; end
    if (cr_v) begin
      for (int i = 0; i < 2; i++) if (cr_k[i] && ctx_y < H && ctx_n < 3 * W) begin ctx_line[ctx_y][ctx_n] = cr_d[8*i +: 8]; ctx_n++; end
      if (cr_l) begin ctx_n = 0; ctx_y++; end
    end
  end
  // LVDS: decode single-link VESA 24 bpp words (lane 0: G0 R5..R0, lane 1: B1 B0 G5..G1,
  // lane 2: DE VS HS B5..B2, lane 3: 0 B7 B6 G7 G6 R7 R6; bit 6 first)
  logic [23:0] lv_frame [H][W]; int lv_x = 0, lv_y = 0, lv_frames = 0; bit lv_vs_q = 0;
  always @(posedge pix_clk) if (pix_rst_n && lvs) begin
    logic [6:0] l0, l1, l2, l3; logic [7:0] r, g, b;
    l0 = lva[6:0]; l1 = lva[13:7]; l2 = lva[20:14]; l3 = lva[27:21];
    r = {l3[1], l3[0], l0[5:0]}; g = {l3[3], l3[2], l1[4:0], l0[6]}; b = {l3[5], l3[4], l2[3:0], l1[6:5]};
    if (l2[5] && !lv_vs_q) begin if (lv_y == OH) lv_frames++; lv_y = 0; lv_x = 0; end
    lv_vs_q = l2[5];
    if (l2[6]) begin if (lv_y < H && lv_x < W) lv_frame[lv_y][lv_x] = {b, g, r}; lv_x++; end
    else if (lv_x != 0) begin lv_x = 0; lv_y++; end
  end
  axil_bfm #(.ADDR_W(15)) bfm (.aclk(pix_clk), .*);
  csi2_lane_driver #(.NL(2)) cam (.clk(byte_clk), .lane_data(ld), .lane_valid(lv));
`ifdef VP_HDMI
  wire sink_en = pix_rst_n;
`else
  wire sink_en = 1'b0;
`endif
  hdmi_sink_model #(.MAXW(64), .MAXH(32)) sink (.clk(pix_clk), .en(sink_en), .ch0(t0), .ch1(t1), .ch2(t2));

  task automatic wr(input int a, input int d); bfm.write(15'(a), 32'(d)); endtask
  task automatic rd(input int a, output logic [31:0] d); bfm.read(15'(a), d); endtask

  // ---------------- scene and camera ----------------
  int raw [H][W];
  localparam int BL = 64;
  initial begin
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int r, g, b, c;
      // colour patches plus gradients, linear light, 10 bit
      r = 120 + 20 * x + ((y / 8) == 1 ? 200 : 0); g = 200 + 10 * y + ((x / 8) == 2 ? 150 : 0); b = 80 + 15 * ((x + y) % 16);
      c = {y[0], x[0]};                             // RGGB
      raw[y][x] = BL + ((c == 0) ? r : (c == 3) ? b : g) / 2;
    end
    raw[10][11] = 1023;                             // hot pixel
    raw[17][20] = 0;                                // dead pixel
  end

  int hdr_err_frame = -1, cam_frames = 0;
  task automatic camera();
    forever begin
      cam.gap = 4; cam.csi_pay.delete(); cam.csi_packet(2'd0, 6'h00, 16'(cam_frames + 1)); send();
      for (int y = 0; y < H; y++) begin
        cam.csi_px.delete(); for (int x = 0; x < W; x++) cam.csi_px.push_back(10'(raw[y][x]));
        cam.csi_pack_raw10();
        cam.csi_packet(2'd0, 6'h2B, 16'(cam.csi_pay.size()));
        if (cam_frames == hdr_err_frame && y == 5) cam.csi_pkt[1] = cam.csi_pkt[1] ^ 8'h10;       // 1 header bit
        cam.gap = 110; send();                       // ~1.1 us per line (display line: 1.18 us)
      end
      cam.csi_pay.delete(); cam.csi_packet(2'd0, 6'h01, 16'(cam_frames + 1)); cam.gap = 1600; send();   // vertical blanking
      cam_frames++;
    end
  endtask
  task automatic send(); cam.send_pkt(); endtask

  // ---------------- configuration and model ----------------
  int blc [4] = '{BL, BL, BL, BL};
  int wb [3] = '{384, 256, 448};                     // R x1.5, G x1, B x1.75
  int thr = 64;
  int ccm [3][3] = '{'{1720, -520, -176}, '{-300, 1580, -256}, '{-60, -610, 1694}};
  int ccm_off [3] = '{0, 0, 0};
  logic [7:0] gam [1024];
  int byp = 8'hC0, bt709 = 0, hdmi = 1, scale2 = 0;

  function automatic int clampi(input int v, input int lo, input int hi); return v < lo ? lo : v > hi ? hi : v; endfunction
  function automatic int mir(input int v, input int n); return v < 0 ? -v : v >= n ? 2 * (n - 1) - v : v; endfunction

  int s1 [H][W], s2 [H][W];                          // after BLC/WB, after DPC
  int s3 [H][W][3], s4 [H][W][3];                    // after demosaic, after CCM (linear RGB)
  logic [23:0] exp_img [H][W];                       // model output (before scaler)
  longint exp_sum [3]; int exp_clip;

  task automatic model();
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int c, v, col; c = {y[0], x[0]}; col = (c == 0) ? 0 : (c == 3) ? 2 : 1;
      v = raw[y][x];
      if (!byp[0]) v = (v > blc[c]) ? v - blc[c] : 0;
      if (!byp[1]) v = clampi((v * wb[col] + 128) >> 8, 0, 1023);
      s1[y][x] = v;
    end
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int mx, mn, c; c = s1[y][x]; mx = 0; mn = 1023;
      for (int dy = -2; dy <= 2; dy += 2) for (int dx = -2; dx <= 2; dx += 2) if (dx != 0 || dy != 0) begin
        int n; n = s1[mir(y + dy, H)][mir(x + dx, W)]; if (n > mx) mx = n; if (n < mn) mn = n;
      end
      s2[y][x] = (!byp[2] && c > mx + thr) ? mx : (!byp[2] && c + thr < mn) ? mn : c;
    end
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int c, cr, dg, hz, vt; c = {y[0], x[0]};
      `define P(xx, yy) s2[mir(yy, H)][mir(xx, W)]
      cr = (`P(x, y-1) + `P(x, y+1) + `P(x-1, y) + `P(x+1, y) + 2) >> 2;
      dg = (`P(x-1, y-1) + `P(x+1, y-1) + `P(x-1, y+1) + `P(x+1, y+1) + 2) >> 2;
      hz = (`P(x-1, y) + `P(x+1, y) + 1) >> 1; vt = (`P(x, y-1) + `P(x, y+1) + 1) >> 1;
      `undef P
      case (c)
        0: begin s3[y][x][0] = s2[y][x]; s3[y][x][1] = cr; s3[y][x][2] = dg; end
        3: begin s3[y][x][0] = dg; s3[y][x][1] = cr; s3[y][x][2] = s2[y][x]; end
        1: begin s3[y][x][0] = hz; s3[y][x][1] = s2[y][x]; s3[y][x][2] = vt; end
        default: begin s3[y][x][0] = vt; s3[y][x][1] = s2[y][x]; s3[y][x][2] = hz; end
      endcase
      if (byp[3]) for (int k = 0; k < 3; k++) s3[y][x][k] = s2[y][x];
    end
    exp_sum = '{0, 0, 0}; exp_clip = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int o [3]; bit clip; clip = 0;
      for (int i = 0; i < 3; i++) begin
        longint s; s = 512; for (int j = 0; j < 3; j++) s += longint'(ccm[i][j]) * s3[y][x][j];
        o[i] = byp[4] ? s3[y][x][i] : clampi(int'(s >>> 10) + ccm_off[i], 0, 1023);
        s4[y][x][i] = o[i]; exp_sum[i] += o[i]; if (o[i] >= 1000) clip = 1;
      end
      exp_clip += clip;
    end
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
      int r, g, b;
      r = byp[5] ? s4[y][x][0] >> 2 : gam[s4[y][x][0]];
      g = byp[5] ? s4[y][x][1] >> 2 : gam[s4[y][x][1]];
      b = byp[5] ? s4[y][x][2] >> 2 : gam[s4[y][x][2]];
      if (!byp[6]) begin
        int yy, cb, cr;
        if (bt709) begin yy = 47*r + 157*g + 16*b + 128; cb = -26*r - 86*g + 112*b + 128; cr = 112*r - 102*g - 10*b + 128; end
        else       begin yy = 66*r + 129*g + 25*b + 128; cb = -38*r - 74*g + 112*b + 128; cr = 112*r - 94*g - 18*b + 128; end
        exp_img[y][x] = {8'(clampi(128 + (cb >>> 8), 0, 255)), 8'(clampi(16 + (yy >>> 8), 0, 255)), 8'(clampi(128 + (cr >>> 8), 0, 255))};
      end else exp_img[y][x] = {8'(b), 8'(g), 8'(r)};
    end
  endtask

  task automatic configure();
    wr(16'h04, 0);                                   // output off while reconfiguring
    wr(16'h08, byp);
    for (int i = 0; i < 4; i++) wr(16'h18 + 4*i, blc[i]);
    for (int i = 0; i < 3; i++) wr(16'h28 + 4*i, wb[i]);
    wr(16'h34, thr);
    for (int i = 0; i < 3; i++) for (int j = 0; j < 3; j++) wr(16'h38 + 4*(3*i + j), ccm[i][j]);
    for (int i = 0; i < 3; i++) wr(16'h5C + 4*i, ccm_off[i]);
    OW = scale2 ? W / 2 : W; OH = scale2 ? H / 2 : H;
    // Without a frame buffer a vertical 2:1 downscale delivers one output
    // line per two camera lines, so the display line time must be at least
    // twice the camera line time: wider horizontal blanking for scale2.
    wr(16'h8C, OW); wr(16'h90, 6); wr(16'h94, 10); wr(16'h98, scale2 ? 220 : 70);
    wr(16'h9C, OH); wr(16'hA0, 2); wr(16'hA4, 2); wr(16'hA8, 3);
    wr(16'hAC, 3); wr(16'hB0, 1023); wr(16'hB4, 16); wr(16'hB8, (2 << 10) | (2 << 8) | 16);
    if (!byp[7]) begin                               // scaler: 1:1 or 2:1, line-buffer mode
      logic [31:0] st;                               // stop it and let it finish before changing it
      wr(16'h4000, 0);
      do rd(16'h4004, st); while (st[0]);
      wr(16'h4000 + 16'h08, (H << 16) | W); wr(16'h4000 + 16'h0C, (OH << 16) | OW);
      wr(16'h4000 + 16'h10, scale2 ? 32'h2_0000 : 32'h1_0000); wr(16'h4000 + 16'h14, scale2 ? 32'h2_0000 : 32'h1_0000);
      wr(16'h4000 + 16'h18, 0); wr(16'h4000 + 16'h1C, 0); wr(16'h4000 + 16'h00, 1);
    end else wr(16'h4000 + 16'h00, 0);
    sink.hdmi = hdmi; sink.vs_active = 1;
    wr(16'h04, 1 | (hdmi << 1) | (1 << 3) | (0 << 4) | (bt709 << 6));      // enable, genlock, RGGB
    model();
  endtask

  // Expected output pixel of scenario 8: the camera model, or the colour bars without a camera
  function automatic logic [23:0] ex(input int x, input int y);
`ifdef VP_CSI2_RX
    return exp_img[y][x];
`else
    case (x / (W / 8))                                             // {B, G, R}
      0: return 24'hFFFFFF; 1: return 24'h00FFFF; 2: return 24'hFFFF00; 3: return 24'h00FF00;
      4: return 24'hFF00FF; 5: return 24'h0000FF; 6: return 24'hFF0000; default: return 24'h000000;
    endcase
`endif
  endfunction
  function automatic int VTOT_DSI(); return OH + 2 + 2 + 3; endfunction   // display lines per frame

  // Wait for settled frames and compare the newest one with the model
  task automatic check_frames(input string what, input int skip = 3);
    int f0; f0 = sink.frames;
    while (sink.frames < f0 + skip) @(posedge pix_clk);
    check(sink.lines == OH && sink.line_len == OW, $sformatf("%s: frame %0dx%0d, exp %0dx%0d", what, sink.line_len, sink.lines, OW, OH));
    begin
      int bad; bad = 0;
      for (int y = 0; y < OH; y++) for (int x = 0; x < OW; x++) begin
        logic [23:0] e; e = scale2 ? exp_img[2*y][2*x] : exp_img[y][x];
        if (sink.frame[y][x] !== e) begin
          if (bad < 3) check(0, $sformatf("%s: pixel (%0d,%0d) = %h exp %h", what, x, y, sink.frame[y][x], e));
          bad++;
        end
      end
      if (bad == 0) $display("%s: %0dx%0d frame matches the model", what, OW, OH);
      else $display("%s: %0d of %0d pixels differ", what, bad, OW * OH);
    end
  endtask

  initial begin
    logic [31:0] v, v2;
    if ($test$plusargs("vcd")) begin $dumpfile("video_pipeline_tb.vcd"); $dumpvars(0, video_pipeline_tb); end
    for (int a = 0; a < 1024; a++) gam[a] = 8'($rtoi(255.0 * ((a / 1023.0) ** (1.0 / 2.2)) + 0.5));
    repeat (5) @(posedge pix_clk); byte_rst_n = 1; pix_rst_n = 1; repeat (5) @(posedge pix_clk);

    rd(16'h00, v); check(v == 32'h5650_4950, $sformatf("ID %h", v));
    begin
      logic [31:0] cfg; cfg = 32'h20;                                   // scaler is built (parameter)
`ifdef VP_CSI2_RX cfg[0] = 1; `endif
`ifdef VP_HDMI    cfg[1] = 1; `endif
`ifdef VP_LVDS    cfg[2] = 1; `endif
`ifdef VP_DSI     cfg[3] = 1; `endif
`ifdef VP_CSI2_TX cfg[4] = 1; `endif
      rd(16'hFC, v); check(v == cfg, $sformatf("BUILD_CFG %h exp %h", v, cfg));
      $display("BUILD_CFG %02h: CSI-2 RX %0d, HDMI %0d, LVDS %0d, DSI %0d, CSI-2 TX %0d", v, v[0], v[1], v[2], v[3], v[4]);
    end
`ifdef VP_CSI2_RX
    wr(16'h14, (H << 16) | W);
    wr(16'h68, 0); for (int a = 0; a < 1024; a++) wr(16'h6C, gam[a]);   // gamma 2.2 table
    fork camera(); join_none
`ifdef VP_HDMI
    if (!$test$plusargs("quick")) begin                             // +quick: only scenario 8

    // 1. full ISP, HDMI, RGB
    byp = 8'h80 | 8'h40; hdmi = 1; bt709 = 0; configure();
    check_frames("1 full ISP, HDMI RGB");
    check(sink.avi_pb[1][6:5] == 2'd0, "AVI: RGB expected");
    rd(16'hD0, v); check(v > 0, "no defective pixels corrected");
    rd(16'h74, v); rd(16'h80, v2);
    check(v == 32'(exp_sum[0]) && v2 == W * H, $sformatf("statistics: sum R %0d exp %0d, pixels %0d", v, exp_sum[0], v2));
    rd(16'h84, v); check(v == exp_clip, $sformatf("statistics: clipped %0d exp %0d", v, exp_clip));
    rd(16'h0C, v); check(v[0], "output not locked to the camera");

    // 2. YCbCr 4:4:4 BT.709
    byp = 8'h80; bt709 = 1; configure();
    check_frames("2 full ISP, HDMI YCbCr 4:4:4 BT.709");
    check(sink.avi_pb[1][6:5] == 2'd2 && sink.avi_pb[2][7:6] == 2'd2, $sformatf("AVI: YCbCr 709 expected, PB1 %02h PB2 %02h", sink.avi_pb[1], sink.avi_pb[2]));

    // 3. everything bypassed, DVI
    byp = 8'hFF; hdmi = 0; configure();
    check_frames("3 all bypassed, DVI");
    check(sink.frame[3][5] == {3{8'(raw[3][5] >> 2)}}, "all-bypass pixel is not the raw value >> 2 on R, G, B");

    // 4. mixed bypass mask: no WB, no CCM, no CSC (+ scaler bypass), HDMI
    byp = 8'h80 | 8'h40 | 8'h10 | 8'h02; hdmi = 1; configure();
    check_frames("4 bypass WB + CCM + CSC");

    // 5. scaler 1:1, then 2:1
    byp = 8'h40; scale2 = 0; configure();
    check_frames("5a scaler 1:1");
    scale2 = 1; configure();
    check_frames("5b scaler 2:1");
    scale2 = 0;

    // 6. test pattern
    byp = 8'hC0; configure(); wr(16'h04, 1 | (1 << 1) | (1 << 2) | (1 << 3));
    begin
      int f0; f0 = sink.frames; while (sink.frames < f0 + 2) @(posedge pix_clk);
      check(sink.frame[0][0] == 24'hFFFFFF && sink.frame[5][W - 1] == 24'h000000 && sink.frame[2][W/8] == 24'h00FFFF,
            "test pattern bars");
      $display("6 test pattern: colour bars");
    end

    // 7. header bit error from the camera: corrected, image unchanged
    byp = 8'hC0; configure();
    rd(16'hC0, v);
    hdr_err_frame = cam_frames + 1;
    check_frames("7 camera header bit error", 4);
    rd(16'hC0, v2); check(v2 == v + 1, $sformatf("ECC_CORR %0d -> %0d", v, v2));
    rd(16'hC4, v); check(v == 0, "uncorrectable ECC errors");
    rd(16'hC8, v); check(v == 0, "CRC errors");
    // Words are lost while the output is stopped for reconfiguration (no frame
    // buffer); in steady streaming none may be lost
    rd(16'hD4, v); check_frames("7b steady streaming", 3); rd(16'hD4, v2);
    check(v2 == v, $sformatf("CSI words lost during steady streaming: %0d", v2 - v));
    rd(16'hBC, v); check(v >= cam_frames - 1, $sformatf("CSI_FRAMES %0d, camera sent %0d", v, cam_frames));
    rd(16'hBC, v); rd(16'hC0, v2);
    $display("status: CSI frames %0d, ECC corrected %0d, statistics, lock checked", v, v2);

    end
`endif   // VP_HDMI
`endif   // VP_CSI2_RX

    // 8. LVDS, CSI-2 TX, DSI (and HDMI) outputs
    byp = 8'hC0; hdmi = 1; scale2 = 0;
`ifdef VP_DSI
    wr(16'hE4, (0 << 24) | (8'h05 << 16) | 16'h0011);              // DSI: DCS exit sleep, sent with video off
`endif
    configure();
`ifndef VP_CSI2_RX
    wr(16'h04, 1 | (1 << 1) | (1 << 2));                            // no camera: test pattern, no genlock
`endif
    wr(16'hD8, (1 << 4) | (1 << 5) | (1 << 8) | (2 << 10));          // DSI video + EoTp, CSI-2 TX RGB888 on VC 2
    begin
      int bad, vss_at, nlines, lf0, cf0; string outs;
      lf0 = lv_frames; cf0 = ctx_frames; outs = "";
      repeat (5) @(posedge dut.v_vs);                               // display frames (vsync active high)
      repeat (20) @(posedge pix_clk);
`ifdef VP_HDMI
      bad = 0; for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (sink.frame[y][x] !== ex(x, y)) bad++;
      check(sink.lines == H && bad == 0, $sformatf("HDMI: %0d lines, %0d of %0d pixels differ", sink.lines, bad, W * H));
      outs = {outs, " HDMI"};
`endif
`ifdef VP_LVDS
      check(lv_frames > lf0, "LVDS: no complete frame decoded");
      bad = 0; for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) if (lv_frame[y][x] !== ex(x, y)) bad++;
      check(bad == 0, $sformatf("LVDS: %0d of %0d pixels differ", bad, W * H));
      outs = {outs, " LVDS"};
`endif
`ifdef VP_CSI2_TX
      check(ctx_frames > cf0 && ctx_err == 0, $sformatf("CSI-2 TX: frames %0d, ECC/CRC errors %0d", ctx_frames - cf0, ctx_err));
      bad = 0; for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) begin
        logic [23:0] e; e = ex(x, y);
        if (ctx_line[y][3*x] != e[23:16] || ctx_line[y][3*x+1] != e[15:8] || ctx_line[y][3*x+2] != e[7:0]) bad++;
      end
      check(bad == 0, $sformatf("CSI-2 TX: %0d of %0d pixels differ", bad, W * H));
      rd(16'hF4, v); check(v == 0, $sformatf("CSI-2 TX: %0d lines dropped", v));
      outs = {outs, " CSI-2-TX"};
`endif
`ifdef VP_DSI
      // the command first, then the last complete frame after a VSS
      check(dsi_rx.log_dt[0] == 6'h05 && dsi_rx.log_data[0] == 16'h0011, "DSI: init command not received first");
      vss_at = -1;
      for (int p = 0; p < dsi_rx.npk; p++) if (dsi_rx.log_dt[p] == 6'h01 && p + 2 * VTOT_DSI() < dsi_rx.npk) vss_at = p;
      check(vss_at >= 0, "DSI: no complete frame after a VSS");
      nlines = 0; bad = 0;
      for (int p = vss_at; vss_at >= 0 && p < dsi_rx.npk && nlines < H; p++) if (dsi_rx.log_dt[p] == 6'h3E) begin
        for (int x = 0; x < W; x++) begin
          int o; logic [23:0] e; o = dsi_rx.log_off[p] + 3 * x; e = ex(x, nlines);
          if (dsi_rx.pay[o] != e[7:0] || dsi_rx.pay[o+1] != e[15:8] || dsi_rx.pay[o+2] != e[23:16]) bad++;
        end
        nlines++;
      end
      check(nlines == H && bad == 0 && dsi_rx.errors == 0, $sformatf("DSI: %0d lines, %0d pixels differ, %0d packet errors", nlines, bad, dsi_rx.errors));
      rd(16'hF0, v); check(v == 0, $sformatf("DSI: %0d lines dropped", v));
      outs = {outs, " DSI"};
`endif
`ifdef VP_CSI2_RX
      $display("8 outputs%s: %0dx%0d camera frame matches the model on each", outs, W, H);
`else
      $display("8 outputs%s: %0dx%0d test pattern on each (no camera input built)", outs, W, H);
`endif
    end

    errors += sink.errors;
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors, %0d from the sink)", errors, sink.errors);
    $finish;
  end
endmodule
