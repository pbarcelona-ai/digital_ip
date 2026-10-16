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
//   Reset - synchronous rst_n (active low). Latency - 2 lines + 7 clocks.
// Date: 2026-10-16
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
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PW
  axis_if.slave s_axis,
  // RAW out
  // m_axis: axis_if.master (ip/shared/src/interfaces/axis_if.sv), DATA_W = PW
  axis_if.master m_axis
);
  assign m_axis.tkeep = '1;      // not used by this block
  axis_if #(.DATA_W(25*PW), .USER_W(1)) u_win_m_axis ();
  logic [15:0] wx, wy;
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
    .s_axis(s_axis),
    .m_axis(u_win_m_axis),
    .m_x(wx),
    .m_y(wy)
  );

  function automatic logic [PW-1:0] tap(input int r, input int c);
    tap = u_win_m_axis.tdata[(r*5 + c)*PW +: PW];
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
  wire  by = u_win_m_axis.tuser ? bypass_i : by_f;
  assign u_win_m_axis.tready = !m_axis.tvalid || m_axis.tready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      by_f <= 1'b0;
      corrected_o <= 1'b0;
      m_axis.tvalid <= 1'b0;
      m_axis.tdata <= '0;
      m_axis.tlast <= 1'b0;
      m_axis.tuser <= 1'b0;
    end else begin
      corrected_o <= 1'b0;
      if (u_win_m_axis.tvalid && u_win_m_axis.tready) begin
        if (u_win_m_axis.tuser) by_f <= bypass_i;
        m_axis.tvalid <= 1'b1;
        m_axis.tlast <= u_win_m_axis.tlast;
        m_axis.tuser <= u_win_m_axis.tuser;
        m_axis.tdata  <= (by || !(hot || dead)) ? c : (hot ? mx : mn);
        corrected_o   <= !by && (hot || dead);
      end else if (m_axis.tready) m_axis.tvalid <= 1'b0;
    end
  end
endmodule
