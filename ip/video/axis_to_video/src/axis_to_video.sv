// ***************
// Filename: axis_to_video.sv
// Author: FPGA Cores 4 U
// Description: AXI-Stream video to timed video output. Version 1.0.0. Buffers
//   the incoming pixel stream in a FIFO and outputs one pixel on every
//   active (de) cycle of a timing generator (vid_timing_gen), all in the
//   pixel clock domain.
//   Frame lock - an output frame starts only from an input start of frame:
//   src_ready_o is high when the FIFO head is an SOF pixel and the FIFO
//   holds at least start_level_i pixels; connect it to the timing
//   generator's src_ready_i (genlock) so the display waits for the source.
//   At sof_i the head must be that SOF pixel, otherwise the frame is output
//   black. If the FIFO runs empty during a frame, or an SOF arrives before
//   the output frame ends, the rest of the frame is black, underflow_o
//   pulses and the block resynchronises: input pixels up to the next SOF
//   are discarded. During vertical blanking (vblank_i) the output frame is
//   over, so leftover input pixels of a longer or interrupted frame are
//   discarded too and the next SOF reaches the FIFO head.
//   Test pattern - with tpg_en_i the input is discarded and eight vertical
//   colour bars (white, yellow, cyan, green, magenta, red, blue, black) are
//   output instead; the pattern is RGB.
//   The output (rgb_o, de_o, hs_o, vs_o) is registered, 1 clock after the
//   timing inputs. Pixel {B, G, R}, component 0 in the LSBs. Clock - clk
//   only. Reset - synchronous rst_n (active low).
// Date: 2026-10-01
module axis_to_video #(
  parameter int PIX_W      = 24,
  parameter int FIFO_DEPTH = 1024              // power of two
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             tpg_en_i,
  input  logic [15:0]      start_level_i,      // pixels buffered before a frame may start
  input  logic [15:0]      h_active_i,         // for the test pattern bar width
  // Video stream in
  input  logic [PIX_W-1:0] s_axis_tdata,
  input  logic             s_axis_tlast,
  input  logic             s_axis_tuser,
  input  logic             s_axis_tvalid,
  output logic             s_axis_tready,
  // Timing in (from vid_timing_gen)
  input  logic             de_i,
  input  logic             hs_i,
  input  logic             vs_i,
  input  logic             sof_i,
  input  logic             vblank_i,
  // Video out
  output logic [PIX_W-1:0] rgb_o,
  output logic             de_o,
  output logic             hs_o,
  output logic             vs_o,
  // Status
  output logic             src_ready_o,
  output logic             locked_o,           // current frame is being taken from the input
  output logic             underflow_o
);
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  logic [PIX_W-1:0] f_data; logic f_last, f_user, f_valid, f_ready, f_tuser_unused; logic [LW-1:0] level;
  ip_axis_fifo #(.DATA_W(PIX_W), .DEPTH(FIFO_DEPTH)) u_fifo (.clk, .rst_n,
    .s_tdata(s_axis_tdata), .s_tlast(s_axis_tlast), .s_tuser(s_axis_tuser), .s_tvalid(s_axis_tvalid), .s_tready(s_axis_tready),
    .m_tdata(f_data), .m_tlast(f_last), .m_tuser(f_user), .m_tvalid(f_valid), .m_tready(f_ready), .level_o(level));

  wire head_sof = f_valid && f_user;
  assign src_ready_o = head_sof && (32'(level) >= 32'(start_level_i));

  logic synced;
  // What happens to this de cycle
  wire start_ok = de_i && sof_i && head_sof;                          // frame starts from the input
  wire take     = !tpg_en_i && de_i && (sof_i ? head_sof : (synced && f_valid && !f_user));
  wire starve   = !tpg_en_i && de_i && !sof_i && synced && !(f_valid && !f_user);
  // Discard: test pattern on, or resynchronising (drop up to the next SOF)
  wire discard  = f_valid && (tpg_en_i || (!synced && !f_user && !(de_i && sof_i)));
  assign f_ready = take || discard;

  // Colour bars: bar index advances every h_active/8 pixels of a line (the
  // last bar takes the remainder). bar / bar_cnt describe the previous pixel.
  logic [15:0] bar_cnt; logic [2:0] bar; logic de_q;
  wire  [15:0] bar_w = (h_active_i >> 3) == 0 ? 16'd1 : (h_active_i >> 3);
  wire         first = de_i && !de_q;
  wire         next  = !first && bar_cnt == bar_w && bar != 3'd7;
  wire  [2:0]  n_bar = first ? 3'd0 : (next ? bar + 1'b1 : bar);
  wire  [15:0] n_cnt = (first || next) ? 16'd1 : bar_cnt + 1'b1;
  logic [23:0] bar_rgb;
  always_comb case (n_bar)                                           // {B, G, R}
    3'd0: bar_rgb = 24'hFFFFFF;  3'd1: bar_rgb = 24'h00FFFF;  3'd2: bar_rgb = 24'hFFFF00;  3'd3: bar_rgb = 24'h00FF00;
    3'd4: bar_rgb = 24'hFF00FF;  3'd5: bar_rgb = 24'h0000FF;  3'd6: bar_rgb = 24'hFF0000;  default: bar_rgb = 24'h000000;
  endcase

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      synced <= 1'b0; bar_cnt <= '0; bar <= '0; de_q <= 1'b0;
      rgb_o <= '0; de_o <= 1'b0; hs_o <= 1'b0; vs_o <= 1'b0; underflow_o <= 1'b0; locked_o <= 1'b0;
    end else begin
      de_q <= de_i;
      if (de_i) begin bar <= n_bar; bar_cnt <= n_cnt; end
      if (tpg_en_i || (vblank_i && !de_i)) synced <= 1'b0;       // frame over: drop leftovers
      else if (de_i && sof_i) synced <= head_sof;
      else if (starve) synced <= 1'b0;
      underflow_o <= starve || (de_i && sof_i && !head_sof && !tpg_en_i && locked_o);
      locked_o    <= tpg_en_i ? 1'b0 : (de_i && sof_i) ? head_sof : (starve ? 1'b0 : locked_o);
      de_o <= de_i; hs_o <= hs_i; vs_o <= vs_i;
      if (!de_i)         rgb_o <= '0;
      else if (tpg_en_i) rgb_o <= PIX_W'(bar_rgb);
      else if (take)     rgb_o <= f_data;
      else               rgb_o <= '0;                                // black while unsynchronised
    end
  end
endmodule
