// ***************
// Filename: isp_demosaic.sv
// Author: FPGA Cores 4 U
// Description: Bayer to RGB demosaic, bilinear 3x3. Version 1.0.0. With the
//   3x3 window (n, s, e, w = cross neighbours, d = diagonals) around a pixel
//   of CFA colour:
//     R:  R = c,           G = (n+s+e+w+2)/4,  B = (sum d + 2)/4
//     B:  B = c,           G = (n+s+e+w+2)/4,  R = (sum d + 2)/4
//     Gr: G = c,  R = (e+w+1)/2,  B = (n+s+1)/2     (green on a red row)
//     Gb: G = c,  B = (e+w+1)/2,  R = (n+s+1)/2     (green on a blue row)
//   Borders are mirrored without repeating the edge pixel (isp_window
//   BORDER = 1), which keeps the CFA colour of every neighbour. CFA pattern
//   cfa_i: 0 RGGB, 1 GRBG, 2 GBRG, 3 BGGR. bypass_i outputs the raw value
//   on all three components (a grey image), so downstream RGB blocks keep
//   working. cfa_i / bypass_i are sampled at the start of each output frame.
//   Output pixel {B, G, R}: component 0 (R) in the LSBs. Clock - clk only.
//   Reset - synchronous rst_n (active low). Latency - 1 line + 6 clocks.
// Date: 2026-10-16
module isp_demosaic #(
  parameter int PW    = 10,
  parameter int MAX_W = 2048
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic [15:0]     width_i,
  input  logic [15:0]     height_i,
  input  logic [1:0]      cfa_i,
  input  logic            bypass_i,
  // RAW in
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PW
  axis_if.slave s_axis,
  // RGB out
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = 3*PW
  axis_if.master m_axis
);
  assign m_axis.tkeep = '1;      // not used by this block
  logic [9*PW-1:0] win;
  logic [15:0] wx, wy;
  logic wl, wu, wv, wr;
  axis_if #(.DATA_W(3*3*PW)) u_win_m_axis ();
  assign win = u_win_m_axis.tdata;
  assign wl = u_win_m_axis.tlast;
  assign wu = u_win_m_axis.tuser;
  assign wv = u_win_m_axis.tvalid;
  assign u_win_m_axis.tready = wr;
  isp_window #(
    .N(3),
    .PW(PW),
    .MAX_W(MAX_W),
    .BORDER(1)
  ) u_win (
    .clk,
    .rst_n,
    .width_i,
    .height_i,
    .s_axis(s_axis),
    .m_axis(u_win_m_axis),
    .m_x(wx),
    .m_y(wy)
  );

  wire [PW-1:0] nw = win[0*PW +: PW], n = win[1*PW +: PW], ne = win[2*PW +: PW];
  wire [PW-1:0] w  = win[3*PW +: PW], c = win[4*PW +: PW], e  = win[5*PW +: PW];
  wire [PW-1:0] sw = win[6*PW +: PW], s = win[7*PW +: PW], se = win[8*PW +: PW];
  wire [PW+1:0] crs = n + s + e + w + 2, diag = nw + ne + sw + se + 2;
  wire [PW:0]   hor = e + w + 1, ver = n + s + 1;
  wire [PW-1:0] g4 = crs[PW+1:2], d4 = diag[PW+1:2], h2 = hor[PW:1], v2 = ver[PW:1];

  logic [1:0] cfa_f;
  logic by_f;
  wire  [1:0] cfa = wu ? cfa_i : cfa_f;
  wire        by  = wu ? bypass_i : by_f;
  wire  [1:0] color = {wy[0] ^ cfa[1], wx[0] ^ cfa[0]};   // 0 R, 1 Gr, 2 Gb, 3 B

  logic [PW-1:0] r, g, b;
  always_comb begin
    case (color)
      2'd0:    begin
        r = c;
        g = g4;
        b = d4;
      end
      2'd3:    begin
        r = d4;
        g = g4;
        b = c;
      end
      2'd1:    begin
        r = h2;
        g = c;
        b = v2;
      end
      default: begin
        r = v2;
        g = c;
        b = h2;
      end
    endcase
    if (by) begin
      r = c;
      g = c;
      b = c;
    end
  end

  assign wr = !m_axis.tvalid || m_axis.tready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cfa_f <= '0;
      by_f <= 1'b0;
      m_axis.tvalid <= 1'b0;
      m_axis.tdata <= '0;
      m_axis.tlast <= 1'b0;
      m_axis.tuser <= 1'b0;
    end else if (wv && wr) begin
      if (wu) begin
        cfa_f <= cfa_i;
        by_f <= bypass_i;
      end
      m_axis.tvalid <= 1'b1;
      m_axis.tdata <= {b, g, r};
      m_axis.tlast <= wl;
      m_axis.tuser <= wu;
    end else if (m_axis.tready) m_axis.tvalid <= 1'b0;
  end
endmodule
