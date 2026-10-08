// ***************
// Filename: vid_timing_gen.sv
// Author: FPGA Cores 4 U
// Description: Programmable video timing generator. Version 1.0.0. Produces
//   de / hsync / vsync for any progressive mode from its active, front
//   porch, sync and back porch lengths (pixels for h, lines for v). Line
//   layout: active, front porch, sync, back porch; frame layout likewise
//   in lines. vsync changes at the hsync leading edge (CEA-861). Sync
//   polarity per hs_pol_i / vs_pol_i (1 = active high).
//   Genlock - with lock_en_i set, the last back-porch line of a frame is
//   repeated while src_ready_i is low (the source has no frame ready), up
//   to lock_max_i extra lines, then the frame starts anyway. Extending
//   vertical blanking line by line keeps hsync regular, so the display
//   follows the source frame rate without a frame buffer; waiting_o is
//   high on extra lines.
//   Outputs are registered (1 clock after the counters): x_o / y_o are the
//   active-area coordinates, sof_o marks the first active pixel of a frame,
//   eol_o the last active pixel of a line, vblank_o the vertical blanking
//   lines. Settings are sampled at frame start. enable_i low holds the
//   generator at the start of a frame with all outputs inactive. Clock -
//   clk (pixel clock) only. Reset - synchronous rst_n (active low).
// Date: 2026-10-01
module vid_timing_gen (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        enable_i,
  input  logic [15:0] h_active_i,
  input  logic [15:0] h_fp_i,
  input  logic [15:0] h_sync_i,
  input  logic [15:0] h_bp_i,
  input  logic [15:0] v_active_i,
  input  logic [15:0] v_fp_i,
  input  logic [15:0] v_sync_i,
  input  logic [15:0] v_bp_i,
  input  logic        hs_pol_i,
  input  logic        vs_pol_i,
  input  logic        lock_en_i,
  input  logic        src_ready_i,
  input  logic [15:0] lock_max_i,
  output logic        de_o,
  output logic        hs_o,
  output logic        vs_o,
  output logic [15:0] x_o,
  output logic [15:0] y_o,
  output logic        sof_o,
  output logic        eol_o,
  output logic        vblank_o,
  output logic        waiting_o
);
  logic [15:0] h, v, extra;
  logic [15:0] ha, hfp, hs, hbp, va, vfp, vs, vbp; logic hpol, vpol;   // per-frame settings
  wire  [15:0] htot = ha + hfp + hs + hbp, vtot = va + vfp + vs + vbp;
  wire  [15:0] hs_start = ha + hfp, vs_start = va + vfp;
  wire  line_end  = (h == htot - 1'b1);
  wire  frame_end = line_end && (v == vtot - 1'b1);
  wire  hold      = frame_end && lock_en_i && !src_ready_i && (extra < lock_max_i);
  // Line number at which vsync is evaluated: before the hsync start the
  // previous line still applies (vsync changes on the hsync leading edge)
  wire  [15:0] vline = (h >= hs_start) ? v : ((v == 0) ? vtot - 1'b1 : v - 1'b1);
  wire  hs_act = (h >= hs_start) && (h < hs_start + hs);
  wire  vs_act = (vline >= vs_start) && (vline < vs_start + vs) && !(waiting_o && h < hs_start);

  always_ff @(posedge clk) begin
    if (!rst_n || !enable_i) begin
      h <= '0; v <= '0; extra <= '0;
      ha <= h_active_i; hfp <= h_fp_i; hs <= h_sync_i; hbp <= h_bp_i;
      va <= v_active_i; vfp <= v_fp_i; vs <= v_sync_i; vbp <= v_bp_i; hpol <= hs_pol_i; vpol <= vs_pol_i;
      de_o <= 1'b0; hs_o <= ~hs_pol_i; vs_o <= ~vs_pol_i; x_o <= '0; y_o <= '0;
      sof_o <= 1'b0; eol_o <= 1'b0; vblank_o <= 1'b0; waiting_o <= 1'b0;
    end else begin
      // counters
      if (!line_end) h <= h + 1'b1;
      else begin
        h <= '0;
        if (hold) begin extra <= extra + 1'b1; waiting_o <= 1'b1; end
        else if (frame_end) begin
          v <= '0; extra <= '0; waiting_o <= 1'b0;
          ha <= h_active_i; hfp <= h_fp_i; hs <= h_sync_i; hbp <= h_bp_i;
          va <= v_active_i; vfp <= v_fp_i; vs <= v_sync_i; vbp <= v_bp_i; hpol <= hs_pol_i; vpol <= vs_pol_i;
        end else v <= v + 1'b1;
      end
      // registered outputs for position (h, v)
      de_o     <= (h < ha) && (v < va);
      x_o      <= h; y_o <= v;
      sof_o    <= (h == 0) && (v == 0);
      eol_o    <= (h == ha - 1'b1) && (v < va);
      vblank_o <= (v >= va);
      hs_o     <= hs_act ? hpol : ~hpol;
      vs_o     <= vs_act ? vpol : ~vpol;
    end
  end
endmodule
