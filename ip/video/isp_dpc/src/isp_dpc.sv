// ***************
// Filename: isp_dpc.sv
// Author: FPGA Cores 4 U
// Description: Bayer defective (hot / dead) pixel correction. Version 1.0.0.
//   Compares each RAW pixel with its 8 same-colour neighbours (two pixels
//   away horizontally, vertically and diagonally, which share the colour in
//   every Bayer pattern):
//     c > max + thr  ->  out = max       (hot pixel)
//     c < min - thr  ->  out = min       (dead pixel)
//     otherwise      ->  out = c
//   Borders are mirrored without repeating the edge pixel (isp_window
//   BORDER = 1), so edge pixels also have 8 true same-colour neighbours.
//   bypass_i
//   (sampled at the start of each output frame) passes the centre pixel
//   unchanged through the same latency. corrected_o pulses once per
//   corrected pixel (for a statistics counter). Frame size from width_i /
//   height_i. Clock - clk only.
//   Reset - synchronous rst_n (active low). Latency - 2 lines + 4 clocks.
// Date: 2026-10-01
module isp_dpc #(
  parameter int PW    = 10,
  parameter int MAX_W = 2048
) (
  input  logic          clk,
  input  logic          rst_n,
  input  logic [15:0]   width_i,
  input  logic [15:0]   height_i,
  input  logic          bypass_i,
  input  logic [PW-1:0] thr_i,
  output logic          corrected_o,
  // RAW in
  input  logic [PW-1:0] s_axis_tdata,
  input  logic          s_axis_tlast,
  input  logic          s_axis_tuser,
  input  logic          s_axis_tvalid,
  output logic          s_axis_tready,
  // RAW out
  output logic [PW-1:0] m_axis_tdata,
  output logic          m_axis_tlast,
  output logic          m_axis_tuser,
  output logic          m_axis_tvalid,
  input  logic          m_axis_tready
);
  logic [25*PW-1:0] win;
  logic [15:0] wx, wy;
  logic wl, wu, wv, wr;
  isp_window #(
    .N(5),
    .PW(PW),
    .MAX_W(MAX_W),
    .BORDER(1)
  ) u_win (
    .clk,
    .rst_n,
    .width_i,
    .height_i,
    .s_axis_tdata,
    .s_axis_tlast,
    .s_axis_tuser,
    .s_axis_tvalid,
    .s_axis_tready,
    .m_axis_tdata(win),
    .m_x(wx),
    .m_y(wy),
    .m_axis_tlast(wl),
    .m_axis_tuser(wu),
    .m_axis_tvalid(wv),
    .m_axis_tready(wr)
  );

  function automatic logic [PW-1:0] tap(input int r, input int c);
    tap = win[(r*5 + c)*PW +: PW];
  endfunction

  logic [PW-1:0] mx, mn, c;
  always_comb begin
    c = tap(2, 2);
    mx = '0;
    mn = '1;
    for (int r = 0; r < 5; r += 2) for (int k = 0; k < 5; k += 2)
      if (!(r == 2 && k == 2)) begin
        if (tap(r, k) > mx) mx = tap(r, k);
        if (tap(r, k) < mn) mn = tap(r, k);
      end
  end
  wire hot  = {1'b0, c} > {1'b0, mx} + {1'b0, thr_i};
  wire dead = {1'b0, c} + {1'b0, thr_i} < {1'b0, mn};

  logic by_f;
  wire  by = wu ? bypass_i : by_f;
  assign wr = !m_axis_tvalid || m_axis_tready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0;
      corrected_o <= 1'b0;
      m_axis_tvalid <= 1'b0;
      m_axis_tdata <= '0;
      m_axis_tlast <= 1'b0;
      m_axis_tuser <= 1'b0;
    end else begin
      corrected_o <= 1'b0;
      if (wv && wr) begin
        if (wu) by_f <= bypass_i;
        m_axis_tvalid <= 1'b1;
        m_axis_tlast <= wl;
        m_axis_tuser <= wu;
        m_axis_tdata  <= (by || !(hot || dead)) ? c : (hot ? mx : mn);
        corrected_o   <= !by && (hot || dead);
      end else if (m_axis_tready) m_axis_tvalid <= 1'b0;
    end
  end
endmodule
