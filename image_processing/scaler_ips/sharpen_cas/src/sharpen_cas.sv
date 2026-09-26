// ***************
// Filename: sharpen_cas.sv
// Author: Paul Barcelona
// Description: Contrast-adaptive sharpening (CAS) filter for AXI4-Stream video, after
//   AMD FidelityFX CAS. Same-size in / out; 3x3 neighbourhood; line-buffer
//   architecture (about two lines of latency, no frame buffer).
//
//   Per pixel and per component, with neighbourhood
//        a b c
//        d e f        (e = centre, M = 2^COMP_W - 1, edges clamp)
//        g h i
//     mn   = min(b,d,e,f,h) + min(a..i)          0 .. 2M   (soft minimum)
//     mx   = max(b,d,e,f,h) + max(a..i)          0 .. 2M   (soft maximum)
//     head = min(mn, 2M - mx)                   headroom before clipping
//     amp  = min(256, (head * RECIP[mx] + 2^15) >> 16),  RECIP[v] = round(2^24 / v)
//            (amp = 256 * head / mx; 0 when mx = 0)          Q8, 0..256
//     sq   = SQRT[amp] = round(16 * sqrt(amp))                Q8, 0..256
//     k    = (sq * G + 128) >> 8,  G = GAIN[SHARPNESS] = round(65536 / (1024 - 3*SHARPNESS))
//     out  = clamp(e + ((k * (4e - b - d - f - h) + 128) >>> 8), 0, M)
//
//   k is the unsharp-mask strength. amp is large in flat or low-contrast areas
//   with headroom and small near clipping or on strong edges, so detail is
//   enhanced without halos. SHARPNESS 0..256 maps the peak strength k from
//   0.25 (G = 64) to 1.0 (G = 256), matching CAS's lerp(8, 5, sharpness)
//   peak. The normalisation divide of the reference CAS, 1 / (1 + 4w), is
//   folded into the unsharp form e + k (4e - neighbours); this is exact at
//   amp = 0 and amp = 1 and monotonic in between (see docs).
//
//   Frame handling: the first beat of a frame must carry tuser (earlier beats
//   are dropped and flag SOF_ERR); tlast must mark column SIZE.W-1 (EOL_ERR);
//   SIZE and SHARPNESS are latched at start of frame. Input is back-pressured
//   when all four line buffers are in use.
//
//   Registers (AXI4-Lite, byte addresses)
//     0x000 CTRL      [0] ENABLE  [1] BYPASS (pass pixels through unchanged)
//     0x004 STATUS    [0] BUSY (RO) [1] FRAME_DONE* [2] SOF_ERR* [3] EOL_ERR*  (*W1C)
//     0x008 SIZE      [15:0] width  [31:16] height
//     0x020 FRAME_CNT (RO)
//     0x024 IP_ID     (RO) "SHRP"
//     0x028 CAPS      (RO) [7:0] 3 (kernel) [15:8] CHANNELS [23:16] COMP_W
//     0x02C MAX_SIZE  (RO) [15:0] MAX_W
//     0x040 SHARPNESS [8:0] 0..256  (0 = gentle, 256 = maximum)
//
//   Throughput: 1 pixel / clock (W+1 cycles per line).
//   Dependencies: axil_regbus
// Date: 2026-09-26

module sharpen_cas #(
  parameter int CHANNELS = 3,
  parameter int COMP_W   = 8,
  parameter int MAX_W    = 1920,
  parameter int ADDR_W   = 8,
  localparam int PIX_W   = CHANNELS * COMP_W
)(
  input  logic              clk,
  input  logic              rst_n,
  // AXI4-Lite
  input  logic [ADDR_W-1:0] s_axil_awaddr,
  input  logic              s_axil_awvalid,
  output logic              s_axil_awready,
  input  logic [31:0]       s_axil_wdata,
  input  logic [3:0]        s_axil_wstrb,
  input  logic              s_axil_wvalid,
  output logic              s_axil_wready,
  output logic [1:0]        s_axil_bresp,
  output logic              s_axil_bvalid,
  input  logic              s_axil_bready,
  input  logic [ADDR_W-1:0] s_axil_araddr,
  input  logic              s_axil_arvalid,
  output logic              s_axil_arready,
  output logic [31:0]       s_axil_rdata,
  output logic [1:0]        s_axil_rresp,
  output logic              s_axil_rvalid,
  input  logic              s_axil_rready,
  // AXI4-Stream in
  input  logic [PIX_W-1:0]  s_axis_tdata,
  input  logic              s_axis_tvalid,
  output logic              s_axis_tready,
  input  logic              s_axis_tuser,
  input  logic              s_axis_tlast,
  // AXI4-Stream out
  output logic [PIX_W-1:0]  m_axis_tdata,
  output logic              m_axis_tvalid,
  input  logic              m_axis_tready,
  output logic              m_axis_tuser,
  output logic              m_axis_tlast
);

  localparam int          M     = (1 << COMP_W) - 1;
  localparam int          XW    = (MAX_W <= 2) ? 1 : $clog2(MAX_W);
  localparam logic [31:0] IP_ID = 32'h5348_5250;              // "SHRP"
  localparam logic [31:0] CAPS  = {8'd0, 8'(COMP_W), 8'(CHANNELS), 8'd3};

  // ===========================================================================
  // Constant tables (ROMs)
  // ===========================================================================
  logic [24:0] recip_rom [0:2*M];
  logic [8:0]  sqrt_rom  [0:256];
  logic [8:0]  gain_rom  [0:256];

  function automatic int isqrt_round(input int v);
    int r;
    r = 0;
    while ((r + 1) * (r + 1) <= v) r++;
    if (v - r * r > r) r++;
    return r;
  endfunction

  initial begin
    recip_rom[0] = '0;
    for (int v = 1; v <= 2 * M; v++) recip_rom[v] = 25'(((1 << 24) + v / 2) / v);
    for (int a = 0; a <= 256; a++)   sqrt_rom[a]  = 9'(isqrt_round(a * 256));
    for (int s = 0; s <= 256; s++)   gain_rom[s]  = 9'((65536 + (1024 - 3 * s) / 2) / (1024 - 3 * s));
  end

  // ===========================================================================
  // Registers
  // ===========================================================================
  logic              reg_wr, reg_rd;
  logic [ADDR_W-1:0] reg_waddr, reg_raddr;
  logic [31:0]       reg_wdata, reg_rdata;
  logic [3:0]        reg_wstrb;

  axil_regbus #(.ADDR_W(ADDR_W), .DATA_W(32)) u_axil (
    .clk, .rst_n,
    .s_axil_awaddr, .s_axil_awvalid, .s_axil_awready,
    .s_axil_wdata,  .s_axil_wstrb,   .s_axil_wvalid, .s_axil_wready,
    .s_axil_bresp,  .s_axil_bvalid,  .s_axil_bready,
    .s_axil_araddr, .s_axil_arvalid, .s_axil_arready,
    .s_axil_rdata,  .s_axil_rresp,   .s_axil_rvalid, .s_axil_rready,
    .reg_wr, .reg_waddr, .reg_wdata, .reg_wstrb,
    .reg_rd, .reg_raddr, .reg_rdata
  );

  logic        enable, bypass;
  logic [15:0] cfg_w, cfg_h;
  logic [8:0]  sharpness;
  logic        st_done, st_sof_err, st_eol_err;
  logic        set_done, set_sof_err, set_eol_err;
  logic [31:0] frame_cnt;
  logic        active;                              // a frame is in flight

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      enable <= 1'b0; bypass <= 1'b0;
      cfg_w <= 16'd1; cfg_h <= 16'd1; sharpness <= 9'd128;
      st_done <= 1'b0; st_sof_err <= 1'b0; st_eol_err <= 1'b0;
      reg_rdata <= '0;
    end else begin
      if (reg_wr) begin
        case (reg_waddr[7:0])
          8'h00: begin enable <= reg_wdata[0]; bypass <= reg_wdata[1]; end
          8'h04: begin
            if (reg_wdata[1]) st_done    <= 1'b0;
            if (reg_wdata[2]) st_sof_err <= 1'b0;
            if (reg_wdata[3]) st_eol_err <= 1'b0;
          end
          8'h08: begin cfg_w <= reg_wdata[15:0]; cfg_h <= reg_wdata[31:16]; end
          8'h40: sharpness <= (reg_wdata[15:0] > 16'd256) ? 9'd256 : reg_wdata[8:0];
          default: ;
        endcase
      end
      if (set_done)    st_done    <= 1'b1;
      if (set_sof_err) st_sof_err <= 1'b1;
      if (set_eol_err) st_eol_err <= 1'b1;
      if (reg_rd) begin
        case (reg_raddr[7:0])
          8'h00:   reg_rdata <= {30'd0, bypass, enable};
          8'h04:   reg_rdata <= {28'd0, st_eol_err, st_sof_err, st_done, active};
          8'h08:   reg_rdata <= {cfg_h, cfg_w};
          8'h20:   reg_rdata <= frame_cnt;
          8'h24:   reg_rdata <= IP_ID;
          8'h28:   reg_rdata <= CAPS;
          8'h2C:   reg_rdata <= 32'(MAX_W);
          8'h40:   reg_rdata <= {23'd0, sharpness};
          default: reg_rdata <= '0;
        endcase
      end
    end
  end

  // ===========================================================================
  // Line buffers: 4 x MAX_W pixels, row r stored in buffer r mod 4
  // ===========================================================================
  logic [PIX_W-1:0] lb [4][MAX_W];

  // ===========================================================================
  // Input side
  // ===========================================================================
  logic [15:0] fw, fh;             // latched frame size
  logic        f_bypass;
  logic [8:0]  f_gain;
  logic [15:0] ix, iy;             // next input pixel
  logic        in_done;
  logic [15:0] rows_rcvd;          // complete rows received
  logic [15:0] rows_read;          // rows whose reads have all been performed

  // row iy may be written once every output row that needs its buffer's
  // previous occupant (row iy-4) has finished reading: rows_read >= iy - 2
  wire row_free = (iy < 16'd4) || (rows_read + 16'd2 >= iy);
  assign s_axis_tready = enable && (!active || (!in_done && row_free));
  wire beat = s_axis_tvalid && s_axis_tready;

  logic out_eof_hs;
  logic rows_read_inc;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      active <= 1'b0; in_done <= 1'b0; ix <= '0; iy <= '0;
      rows_rcvd <= '0; fw <= 16'd1; fh <= 16'd1; f_bypass <= 1'b0; f_gain <= 9'd64;
      set_done <= 1'b0; set_sof_err <= 1'b0; set_eol_err <= 1'b0; frame_cnt <= '0;
    end else begin
      set_done <= 1'b0; set_sof_err <= 1'b0; set_eol_err <= 1'b0;
      if (beat) begin
        logic [15:0] w, h, x, y;
        w = active ? fw : cfg_w;
        h = active ? fh : cfg_h;
        x = active ? ix : 16'd0;
        y = active ? iy : 16'd0;
        if (!active && !s_axis_tuser) begin
          set_sof_err <= 1'b1;                          // no SOF yet: drop
        end else begin
          if (!active) begin                            // start of frame
            active   <= 1'b1;
            in_done  <= 1'b0;
            fw       <= cfg_w;
            fh       <= cfg_h;
            f_bypass <= bypass;
            f_gain   <= gain_rom[sharpness];
            rows_rcvd <= '0;
          end else if (s_axis_tuser) begin
            set_sof_err <= 1'b1;                        // SOF inside a frame
          end
          lb[y[1:0]][x] <= s_axis_tdata;
          if (s_axis_tlast != (x == w - 16'd1)) set_eol_err <= 1'b1;
          if (x == w - 16'd1) begin
            ix <= '0;
            iy <= y + 16'd1;
            rows_rcvd <= (active ? rows_rcvd : 16'd0) + 16'd1;
            if (y == h - 16'd1) in_done <= 1'b1;
          end else begin
            ix <= x + 16'd1;
            iy <= y;
          end
        end
      end
      if (out_eof_hs) begin
        active    <= 1'b0;
        frame_cnt <= frame_cnt + 32'd1;
        set_done  <= 1'b1;
      end
    end
  end

  // ===========================================================================
  // Output engine
  // ===========================================================================
  wire adv = !m_axis_tvalid || m_axis_tready;

  logic [15:0] oy, oj;                  // output row, read column 0..fw
  logic        eng_done;

  // rows needed before row oy can be read
  wire [15:0] need = (oy + 16'd2 < fh) ? oy + 16'd2 : fh;
  wire        can_issue = active && !eng_done && (rows_rcvd >= need);

  // ---- stage 0: read address / row selects
  logic          s0_v, s0_first, s0_emit, s0_rowlast, s0_sof, s0_eol, s0_eof;
  logic [XW-1:0] s0_col;
  logic [1:0]    s0_bt, s0_bm, s0_bb;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      oy <= '0; oj <= '0; eng_done <= 1'b0; s0_v <= 1'b0;
      s0_first <= 0; s0_emit <= 0; s0_rowlast <= 0; s0_sof <= 0; s0_eol <= 0; s0_eof <= 0;
      s0_col <= '0; s0_bt <= '0; s0_bm <= '0; s0_bb <= '0;
    end else if (beat && !active) begin     // new frame: restart engine
      oy <= '0; oj <= '0; eng_done <= 1'b0; s0_v <= 1'b0;
    end else if (adv) begin
      s0_v <= can_issue;
      if (can_issue) begin
        logic [15:0] yt, yb;
        yt = (oy == 16'd0) ? 16'd0 : oy - 16'd1;
        yb = (oy + 16'd1 >= fh) ? fh - 16'd1 : oy + 16'd1;
        s0_col     <= XW'((oj < fw) ? oj : fw - 16'd1);
        s0_bt      <= yt[1:0];
        s0_bm      <= oy[1:0];
        s0_bb      <= yb[1:0];
        s0_first   <= (oj == 16'd0);
        s0_emit    <= (oj != 16'd0);
        s0_rowlast <= (oj == fw);
        s0_sof     <= (oy == 16'd0) && (oj == 16'd1);
        s0_eol     <= (oj == fw);
        s0_eof     <= (oj == fw) && (oy == fh - 16'd1);
        if (oj == fw) begin
          oj <= '0;
          oy <= oy + 16'd1;
          if (oy == fh - 16'd1) eng_done <= 1'b1;
        end else begin
          oj <= oj + 16'd1;
        end
      end
    end
  end

  // rows_read counts rows whose last RAM read has been performed
  assign rows_read_inc = adv && s0_v && s0_rowlast;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)                  rows_read <= '0;
    else if (beat && !active)    rows_read <= '0;
    else if (rows_read_inc)      rows_read <= rows_read + 16'd1;
  end

  // ---- stage 1: RAM read (all four buffers, same column)
  logic [PIX_W-1:0] bq [4];
  logic             s1_v, s1_first, s1_emit, s1_sof, s1_eol, s1_eof;
  logic [1:0]       s1_bt, s1_bm, s1_bb;

  always_ff @(posedge clk) begin
    if (adv) begin
      for (int b = 0; b < 4; b++) bq[b] <= lb[b][s0_col];
      s1_bt <= s0_bt; s1_bm <= s0_bm; s1_bb <= s0_bb;
      s1_first <= s0_first; s1_emit <= s0_emit;
      s1_sof <= s0_sof; s1_eol <= s0_eol; s1_eof <= s0_eof;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               s1_v <= 1'b0;
    else if (beat && !active) s1_v <= 1'b0;
    else if (adv)             s1_v <= s0_v;
  end

  // ---- stage 2: 3x3 window shift register  w[row][col], col 0 = left
  logic [PIX_W-1:0] wn [3][3];
  logic             s2_v, s2_sof, s2_eol, s2_eof;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_v <= 1'b0; s2_sof <= 0; s2_eol <= 0; s2_eof <= 0;
    end else if (beat && !active) begin
      s2_v <= 1'b0;
    end else if (adv) begin
      s2_v <= s1_v && s1_emit;
      if (s1_v) begin
        logic [PIX_W-1:0] col [3];
        col[0] = bq[s1_bt]; col[1] = bq[s1_bm]; col[2] = bq[s1_bb];
        for (int r = 0; r < 3; r++) begin
          if (s1_first) begin
            wn[r][0] <= col[r]; wn[r][1] <= col[r]; wn[r][2] <= col[r];
          end else begin
            wn[r][0] <= wn[r][1]; wn[r][1] <= wn[r][2]; wn[r][2] <= col[r];
          end
        end
        s2_sof <= s1_sof; s2_eol <= s1_eol; s2_eof <= s1_eof;
      end
    end
  end

  // ---- stage 3 (comb -> reg): soft min/max, amplitude, laplacian
  localparam int DW = COMP_W + 4;
  // amplitude for one component from its 3x3 neighbourhood
  //   a b c / d e f / g h i
  function automatic logic [8:0] cas_amp(input int a, input int b, input int c,
                                         input int d, input int e, input int f,
                                         input int g, input int h, input int i);
    int mn5, mx5, mn9, mx9, mn, mx, head, amp;
    mn5 = e; mx5 = e;
    if (b < mn5) mn5 = b;  if (b > mx5) mx5 = b;
    if (d < mn5) mn5 = d;  if (d > mx5) mx5 = d;
    if (f < mn5) mn5 = f;  if (f > mx5) mx5 = f;
    if (h < mn5) mn5 = h;  if (h > mx5) mx5 = h;
    mn9 = mn5; mx9 = mx5;
    if (a < mn9) mn9 = a;  if (a > mx9) mx9 = a;
    if (c < mn9) mn9 = c;  if (c > mx9) mx9 = c;
    if (g < mn9) mn9 = g;  if (g > mx9) mx9 = g;
    if (i < mn9) mn9 = i;  if (i > mx9) mx9 = i;
    mn   = mn5 + mn9;
    mx   = mx5 + mx9;
    head = (mn < 2 * M - mx) ? mn : 2 * M - mx;
    if (mx == 0) amp = 0;
    else begin
      amp = int'((longint'(head) * longint'(recip_rom[mx]) + 64'd32768) >> 16);
      if (amp > 256) amp = 256;
    end
    return 9'(amp);
  endfunction

  function automatic int cmp(input logic [PIX_W-1:0] p, input int c);
    return int'(p[c*COMP_W +: COMP_W]);
  endfunction

  logic [8:0]           amp_c [CHANNELS];
  logic signed [DW-1:0] d_c   [CHANNELS];
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      amp_c[c] = cas_amp(cmp(wn[0][0], c), cmp(wn[0][1], c), cmp(wn[0][2], c),
                         cmp(wn[1][0], c), cmp(wn[1][1], c), cmp(wn[1][2], c),
                         cmp(wn[2][0], c), cmp(wn[2][1], c), cmp(wn[2][2], c));
      d_c[c]   = DW'(4 * cmp(wn[1][1], c) - cmp(wn[0][1], c) - cmp(wn[1][0], c)
                     - cmp(wn[1][2], c) - cmp(wn[2][1], c));
    end
  end

  logic [8:0]           s3_amp [CHANNELS];
  logic signed [DW-1:0] s3_d   [CHANNELS];
  logic [PIX_W-1:0]     s3_ctr;
  logic                 s3_v, s3_sof, s3_eol, s3_eof;

  always_ff @(posedge clk) begin
    if (adv) begin
      for (int c = 0; c < CHANNELS; c++) begin
        s3_amp[c] <= amp_c[c];
        s3_d[c]   <= d_c[c];
      end
      s3_ctr <= wn[1][1];
      s3_sof <= s2_sof; s3_eol <= s2_eol; s3_eof <= s2_eof;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n)               s3_v <= 1'b0;
    else if (beat && !active) s3_v <= 1'b0;
    else if (adv)             s3_v <= s2_v;
  end

  // ---- stage 4 (comb -> output reg): sqrt, strength, apply
  logic [PIX_W-1:0] out_c;
  always_comb begin
    for (int c = 0; c < CHANNELS; c++) begin
      int k, e, v;
      k = (int'(sqrt_rom[s3_amp[c]]) * int'(f_gain) + 128) >>> 8;
      e = int'(s3_ctr[c*COMP_W +: COMP_W]);
      v = e + ((k * int'(s3_d[c]) + 128) >>> 8);
      if (f_bypass) v = e;
      out_c[c*COMP_W +: COMP_W] = COMP_W'((v < 0) ? 0 : (v > M) ? M : v);
    end
  end

  logic m_eof;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_axis_tuser <= 1'b0;
      m_axis_tlast <= 1'b0; m_eof <= 1'b0;
    end else if (adv) begin
      m_axis_tvalid <= s3_v;
      m_axis_tdata  <= out_c;
      m_axis_tuser  <= s3_sof;
      m_axis_tlast  <= s3_eol;
      m_eof         <= s3_eof;
    end
  end

  assign out_eof_hs = m_axis_tvalid && m_axis_tready && m_eof;

endmodule
