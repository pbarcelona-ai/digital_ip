// ***************
// Filename: video_pipeline_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the video_pipeline_tb testbench
//   (video_pipeline_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check         Counts an error and prints the message when the condition
//                   is false
//     wr            Register write over the bus
//     rd            Register read over the bus
//     camera
//     send
//     model
//     configure
//     check_frames  Wait for settled frames and compare the newest one with
//                   the model
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  task automatic wr(input int a, input int d); bfm.write(15'(a), 32'(d)); endtask

  task automatic rd(input int a, output logic [31:0] d); bfm.read(15'(a), d); endtask

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
