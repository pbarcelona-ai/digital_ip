// ***************
// Filename: isp_stats.sv
// Author: FPGA Cores 4 U
// Description: Per-frame image statistics for auto exposure and auto white
//   balance software. Version 1.0.0. Monitors an RGB AXI-Stream (it only
//   observes the handshake, it never stalls the stream) and accumulates
//   over each frame: the sum of each component, the number of pixels, and
//   the number of pixels with any component >= sat_thr_i (clipping). At the
//   start of the next frame (tuser) the totals are copied to the outputs
//   and frame_done_o pulses, so the outputs always describe the last
//   complete frame and stay stable for a whole frame time. A frame that is
//   never followed by another is reported when flush_i pulses. Clock - clk
//   only. Reset - synchronous rst_n (active low).
// Date: 2026-10-01
module isp_stats #(
  parameter int CW = 8                         // component width
) (
  input  logic            clk,
  input  logic            rst_n,
  input  logic [CW-1:0]   sat_thr_i,
  input  logic            flush_i,
  // Monitored stream
  input  logic [3*CW-1:0] tdata,               // {B, G, R}
  input  logic            tuser,
  input  logic            tvalid,
  input  logic            tready,
  // Results of the last complete frame
  output logic [39:0]     sum_r_o,
  output logic [39:0]     sum_g_o,
  output logic [39:0]     sum_b_o,
  output logic [31:0]     pixels_o,
  output logic [31:0]     clipped_o,
  output logic [31:0]     frames_o,
  output logic            frame_done_o
);
  logic [39:0] ar, ag, ab;
  logic [31:0] np, nc;
  logic active;
  wire beat = tvalid && tready;
  wire [CW-1:0] r = tdata[0 +: CW], g = tdata[CW +: CW], b = tdata[2*CW +: CW];
  wire clip = (r >= sat_thr_i) || (g >= sat_thr_i) || (b >= sat_thr_i);
  wire close = (beat && tuser && active) || (flush_i && active);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ar <= '0;
      ag <= '0;
      ab <= '0;
      np <= '0;
      nc <= '0;
      active <= 1'b0;
      sum_r_o <= '0;
      sum_g_o <= '0;
      sum_b_o <= '0;
      pixels_o <= '0;
      clipped_o <= '0;
      frames_o <= '0;
      frame_done_o <= 1'b0;
    end else begin
      frame_done_o <= close;
      if (close) begin
        sum_r_o <= ar;
        sum_g_o <= ag;
        sum_b_o <= ab;
        pixels_o <= np;
        clipped_o <= nc;
        frames_o <= frames_o + 1'b1;
      end
      if (beat && tuser) begin                 // first pixel of a frame starts new totals
        ar <= 40'(r);
        ag <= 40'(g);
        ab <= 40'(b);
        np <= 32'd1;
        nc <= 32'(clip);
        active <= 1'b1;
      end else if (beat && active) begin
        ar <= ar + r;
        ag <= ag + g;
        ab <= ab + b;
        np <= np + 1'b1;
        nc <= nc + clip;
      end else if (flush_i) active <= 1'b0;
    end
  end
endmodule
