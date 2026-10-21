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
// Date: 2026-10-21
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
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = PIX_W
  axis_if.slave s_axis,
  // Timing in (from vid_timing_gen)
  // tim: vid_if.sink (ip/shared/src/interfaces/vid_if.sv) {de_i=de hs_i=hs vs_i=vs}
  vid_if.sink tim,
  input  logic             sof_i,
  input  logic             vblank_i,
  // Video out
  // vid: vid_if.source (ip/shared/src/interfaces/vid_if.sv), DATA_W = PIX_W {rgb_o=data de_o=de hs_o=hs vs_o=vs}
  vid_if.source vid,
  // Status
  output logic             src_ready_o,
  output logic             locked_o,           // current frame is being taken from the input
  output logic             underflow_o
);
  localparam int LW = $clog2(FIFO_DEPTH) + 2;
  logic [PIX_W-1:0] f_data;
  logic f_last, f_user, f_valid, f_ready, f_tuser_unused;
  logic [LW-1:0] level;
  axis_if #(.DATA_W(PIX_W)) u_fifo_m ();
  assign f_data = u_fifo_m.tdata;
  assign f_last = u_fifo_m.tlast;
  assign f_user = u_fifo_m.tuser;
  assign f_valid = u_fifo_m.tvalid;
  assign u_fifo_m.tready = f_ready;
  ip_axis_fifo #(
    .DATA_W(PIX_W),
    .DEPTH(FIFO_DEPTH)
  ) u_fifo (
    .clk,
    .rst_n,
    .s(s_axis),
    .m(u_fifo_m),
    .level_o(level)
  );

  wire head_sof = f_valid && f_user;
  assign src_ready_o = head_sof && (32'(level) >= 32'(start_level_i));

  logic synced;
  // What happens to this de cycle
  wire start_ok = tim.de && sof_i && head_sof;                          // frame starts from the input
  wire take     = !tpg_en_i && tim.de && (sof_i ? head_sof : (synced && f_valid && !f_user));
  wire starve   = !tpg_en_i && tim.de && !sof_i && synced && !(f_valid && !f_user);
  // Discard: test pattern on, or resynchronising (drop up to the next SOF)
  wire discard  = f_valid && (tpg_en_i || (!synced && !f_user && !(tim.de && sof_i)));
  assign f_ready = take || discard;

  // Colour bars: bar index advances every h_active/8 pixels of a line (the
  // last bar takes the remainder). bar / bar_cnt describe the previous pixel.
  logic [15:0] bar_cnt;
  logic [2:0] bar;
  logic de_q;
  wire  [15:0] bar_w = (h_active_i >> 3) == 0 ? 16'd1 : (h_active_i >> 3);
  wire         first = tim.de && !de_q;
  wire         next  = !first && bar_cnt == bar_w && bar != 3'd7;
  wire  [2:0]  n_bar = first ? 3'd0 : (next ? bar + 1'b1 : bar);
  wire  [15:0] n_cnt = (first || next) ? 16'd1 : bar_cnt + 1'b1;
  logic [23:0] bar_rgb;
  always_comb case (n_bar)                                           // {B, G, R}
    3'd0: bar_rgb = 24'hFFFFFF;
    3'd1: bar_rgb = 24'h00FFFF;
    3'd2: bar_rgb = 24'hFFFF00;
    3'd3: bar_rgb = 24'h00FF00;
    3'd4: bar_rgb = 24'hFF00FF;
    3'd5: bar_rgb = 24'h0000FF;
    3'd6: bar_rgb = 24'hFF0000;
    default: bar_rgb = 24'h000000;
  endcase

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      synced <= 1'b0;
      bar_cnt <= '0;
      bar <= '0;
      de_q <= 1'b0;
      vid.data <= '0;
      vid.de <= 1'b0;
      vid.hs <= 1'b0;
      vid.vs <= 1'b0;
      underflow_o <= 1'b0;
      locked_o <= 1'b0;
    end else begin
      de_q <= tim.de;
      if (tim.de) begin
        bar <= n_bar;
        bar_cnt <= n_cnt;
      end
      if (tpg_en_i || (vblank_i && !tim.de)) synced <= 1'b0;       // frame over: drop leftovers
      else if (tim.de && sof_i) synced <= head_sof;
      else if (starve) synced <= 1'b0;
      underflow_o <= starve || (tim.de && sof_i && !head_sof && !tpg_en_i && locked_o);
      locked_o    <= tpg_en_i ? 1'b0 : (tim.de && sof_i) ? head_sof : (starve ? 1'b0 : locked_o);
      vid.de <= tim.de;
      vid.hs <= tim.hs;
      vid.vs <= tim.vs;
      if (!tim.de)         vid.data <= '0;
      else if (tpg_en_i) vid.data <= PIX_W'(bar_rgb);
      else if (take)     vid.data <= f_data;
      else               vid.data <= '0;                                // black while unsynchronised
    end
  end
  // not used: the FIFO's tlast (lines are counted), the start condition kept for reading
  wire unused_ok = &{1'b0, f_last, start_ok, 1'b0};
endmodule
