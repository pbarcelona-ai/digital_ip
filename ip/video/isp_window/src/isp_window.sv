// ***************
// Filename: isp_window.sv
// Author: FPGA Cores 4 U
// Description: N x N neighbourhood (window) generator for streaming video.
//   Version 1.0.0. For every input pixel it outputs the N x N window
//   centred on it, in raster order, using N-1 line buffers (block RAM).
//   The output frame has the same size as the input; pixels outside the
//   frame come from the BORDER rule:
//     BORDER = 0  clamp to edge   (x = -1 -> 0,  x = W -> W-1)
//     BORDER = 1  mirror, edge not repeated (reflect-101: x = -1 -> 1,
//                 x = W -> W-2). This keeps the colour phase of Bayer data,
//                 so it is the right choice before demosaic. Needs
//                 W, H >= R + 1.
//   The frame size comes from width_i / height_i
//   (static during a frame); the block scans a (W+R) x (H+R) grid, R =
//   (N-1)/2, and generates the last R columns and rows itself, so a frame
//   is complete without waiting for the next one.
//   Window layout - m_axis_tdata[(r*N + c)*PW +: PW] is row r (0 = top),
//   column c (0 = left); the centre is r = c = R. m_x / m_y give the
//   centre coordinates. tuser = SOF, tlast = EOL, as on the input.
//   Resync - input pixels before a start-of-frame pixel are dropped, and a
//   start-of-frame pixel arriving where the scan expects an ordinary pixel
//   (a short frame, or a size change mid-frame) restarts the scan at (0,0)
//   with it; windows already output for the short frame remain valid.
//   sof_wait_o - high while the scan waits for a frame's first pixel (between
//   frames; registered, independent of the inputs): a parent may switch
//   width_i / height_i when it sees a start-of-frame pixel in that state.
//   Throughput - 1 pixel per clock plus R idle input cycles per line and R
//   lines per frame. Clock - clk only. Reset - synchronous rst_n (active
//   low). Latency - R lines + R + 1 clocks.
// Date: 2026-10-01
module isp_window #(
  parameter int N     = 3,                     // window size, odd, >= 3
  parameter int PW    = 10,                    // pixel width
  parameter int MAX_W = 2048,                  // longest line
  parameter int BORDER = 0                     // 0 clamp to edge, 1 mirror (reflect-101)
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic [15:0]         width_i,         // 1 + R .. MAX_W
  input  logic [15:0]         height_i,        // >= 1 + R
  // Pixels in
  input  logic [PW-1:0]       s_axis_tdata,
  input  logic                s_axis_tlast,
  input  logic                s_axis_tuser,
  input  logic                s_axis_tvalid,
  output logic                s_axis_tready,
  // Windows out
  output logic [N*N*PW-1:0]   m_axis_tdata,
  output logic [15:0]         m_x,
  output logic [15:0]         m_y,
  output logic                m_axis_tlast,
  output logic                m_axis_tuser,
  output logic                m_axis_tvalid,
  input  logic                m_axis_tready,
  output logic                sof_wait_o       // scan at (0,0), waiting for a frame start
);
  if (N < 3 || N % 2 == 0) begin : g_bad $error("isp_window: N must be odd and >= 3"); end
  localparam int R  = (N - 1) / 2;
  localparam int AW = $clog2(MAX_W);

  logic [15:0] x, y;                           // scan position (input coordinates)
  wire  [15:0] xend = width_i + 16'(R - 1), yend = height_i + 16'(R - 1);
  wire need_in = (x < width_i) && (y < height_i);
  wire prod    = (x >= 16'(R)) && (y >= 16'(R));
  wire o_free  = !m_axis_tvalid || m_axis_tready;
  wire at_sof  = (x == 0) && (y == 0);
  assign sof_wait_o = at_sof;
  wire drop    = need_in && at_sof && s_axis_tvalid && !s_axis_tuser;   // wait for SOF
  wire restart = need_in && !at_sof && s_axis_tvalid && s_axis_tuser;   // early SOF: start over
  wire advance = (need_in ? (s_axis_tvalid && !drop && !restart) : 1'b1) && (!prod || o_free);
  assign s_axis_tready = need_in && !restart && (drop || !prod || o_free);

  wire [15:0] nx = (x == xend) ? 16'd0 : x + 16'd1;
  wire [15:0] ny = (x == xend) ? ((y == yend) ? 16'd0 : y + 16'd1) : y;

  // ---------------- line buffers: lb[j] holds raw row y-1-j, read one clock ahead
  logic [PW-1:0] q [N-1];
  logic [PW-1:0] raw [N];                      // raw rows at x, raw[k] = row y-k
  logic [PW-1:0] col [N];                      // column at x after the border rule
  wire  [15:0] raddr16 = advance ? nx : x;
  wire  [AW-1:0] raddr = (raddr16 < width_i) ? raddr16[AW-1:0] : '0;
  wire  wr_en = advance && (x < width_i);
  for (genvar j = 0; j < N - 1; j++) begin : g_lb
    logic [PW-1:0] mem [MAX_W];
    always_ff @(posedge clk) begin
      if (wr_en) mem[x[AW-1:0]] <= raw[j];
      q[j] <= mem[raddr];
    end
  end

  // ---------------- column assembly
  // cstore[c][k]: window column c (0 = oldest, N-1 = newest), row y-k.
  // Rows outside the frame are remapped to a real row of the same column:
  // row -m -> 0 (clamp) or m (mirror); row H-1+m -> H-1 or H-1-m. Only
  // windows of scan rows y >= R are output, and for those every remapped
  // row has already been received.
  logic [PW-1:0] cstore [N][N];
  always_comb begin
    int yi, hi, d, sc;
    yi = int'(y); hi = int'(height_i);
    d = int'(x) - int'(width_i) + 1;
    sc = (BORDER != 0) ? N - 2*d : N - 1;
    raw[0] = (y >= height_i) ? q[0] : s_axis_tdata;          // below the frame: placeholder
    for (int k = 1; k < N; k++) raw[k] = q[k-1];
    for (int k = 0; k < N; k++) begin : vrow
      int src, row;
      row = yi - k; src = k;
      if (row < 0)        src = (BORDER != 0) ? 2*yi - k : yi;
      else if (row >= hi) src = (BORDER != 0) ? 2*yi - k - 2*hi + 2 : yi - hi + 1;
      col[k] = raw[0];
      for (int j = 0; j < N; j++) if (j == src) col[k] = raw[j];
    end
    // Right of the frame: column W-1+d is column W-1 (clamp) or W-1-d (mirror),
    // which is window column N-1 or N-2d of the stored columns.
    if (x >= width_i) begin
      for (int k = 0; k < N; k++) begin
        col[k] = cstore[N-1][k];
        for (int j = 0; j < N; j++) if (j == sc) col[k] = cstore[j][k];
      end
    end
  end

  // Window after this step; columns left of x = 0 come from the border rule
  logic [N*N*PW-1:0] win;
  always_comb begin
    win = '0;
    for (int c = 0; c < N; c++) begin : wcol
      int src, xc;
      src = c; xc = int'(x) - (N - 1) + c;                   // image column of window column c
      if (xc < 0) src = (BORDER != 0) ? 2*(N - 1) - 2*int'(x) - c : (N - 1) - int'(x);
      for (int r = 0; r < N; r++)
        for (int s = 0; s < N; s++) if (s == src)
          win[(r*N + c)*PW +: PW] = (s == N - 1) ? col[N-1-r] : cstore[(s == N - 1) ? s : s + 1][N-1-r];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      x <= '0; y <= '0;
      m_axis_tvalid <= 1'b0; m_axis_tdata <= '0; m_x <= '0; m_y <= '0; m_axis_tlast <= 1'b0; m_axis_tuser <= 1'b0;
    end else begin
      if (restart) begin x <= '0; y <= '0; end
      else if (advance) begin
        x <= nx; y <= ny;
        for (int c = 0; c < N - 1; c++) for (int k = 0; k < N; k++) cstore[c][k] <= cstore[c+1][k];
        for (int k = 0; k < N; k++) cstore[N-1][k] <= col[k];
      end
      if (advance && prod) begin
        m_axis_tvalid <= 1'b1; m_axis_tdata <= win;
        m_x <= x - 16'(R); m_y <= y - 16'(R);
        m_axis_tuser <= (x == 16'(R)) && (y == 16'(R));
        m_axis_tlast <= (x == xend);
      end else if (m_axis_tready) m_axis_tvalid <= 1'b0;
    end
  end
endmodule
