// ***************
// Filename: scaler_dda.sv
// Author: Paul Barcelona
// Description: Output raster scan / source coordinate generator.
//   Scans the output image in raster order and produces, for every output
//   pixel, the source coordinate in signed 16.16 fixed point:
//     src_x(ox) = OFFS_X + ox * STEP_X
//     src_y(oy) = OFFS_Y + oy * STEP_Y
//   The products are replaced by exact accumulation (a digital
//   differential analyser), so hardware and reference models agree bit
//   for bit. Also outputs SOF / EOL / EOF flags. Outputs are registered
//   and only advance when adv = 1, so the block can head a stall-able
//   pipeline. 'start' re-initialises the scan for a new frame.
// Date: 2026-09-26

module scaler_dda (
  input  logic               clk,
  input  logic               rst_n,      // async reset, active low
  input  logic               start,      // 1-cycle pulse: begin a new frame
  input  logic               adv,        // pipeline advance
  input  logic [15:0]        out_w,      // output width  (pixels)
  input  logic [15:0]        out_h,      // output height (lines)
  input  logic [31:0]        step_x,     // unsigned 16.16
  input  logic [31:0]        step_y,     // unsigned 16.16
  input  logic signed [31:0] offs_x,     // signed 16.16
  input  logic signed [31:0] offs_y,     // signed 16.16
  output logic               busy,       // pixels left to issue
  output logic               o_valid,    // o_* hold a valid pixel
  output logic signed [31:0] o_x,        // source x, signed 16.16
  output logic signed [31:0] o_y,        // source y, signed 16.16
  output logic               o_sof,      // first pixel of frame
  output logic               o_eol,      // last pixel of a line
  output logic               o_eof       // last pixel of frame
);

  logic [15:0]        ox, oy;   // output position of the next pixel
  logic signed [31:0] ax, ay;   // source coordinate of the next pixel

  // end-of-line / end-of-frame detection for the next pixel
  wire last_col = (ox == out_w - 16'd1);
  wire last_row = (oy == out_h - 16'd1);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy    <= 1'b0;
      ox      <= '0;
      oy      <= '0;
      ax      <= '0;
      ay      <= '0;
      o_valid <= 1'b0;
      o_x     <= '0;
      o_y     <= '0;
      o_sof   <= 1'b0;
      o_eol   <= 1'b0;
      o_eof   <= 1'b0;
    end else if (start) begin
      // new frame: restart at output (0,0) = source (OFFS_X, OFFS_Y)
      busy    <= 1'b1;
      ox      <= '0;
      oy      <= '0;
      ax      <= offs_x;
      ay      <= offs_y;
      o_valid <= 1'b0;
    end else if (adv) begin
      // present the next pixel (or a bubble once the frame is done)
      o_valid <= busy;
      if (busy) begin
        o_x   <= ax;
        o_y   <= ay;
        o_sof <= (ox == 16'd0) && (oy == 16'd0);
        o_eol <= last_col;
        o_eof <= last_col && last_row;
        if (last_col) begin
          // end of line: rewind x, step y to the next output line
          ox <= '0;
          ax <= offs_x;
          ay <= ay + $signed(step_y);
          oy <= oy + 16'd1;
          if (last_row) busy <= 1'b0;      // last pixel issued
        end else begin
          // next pixel on the same line
          ox <= ox + 16'd1;
          ax <= ax + $signed(step_x);
        end
      end
    end
  end

endmodule
