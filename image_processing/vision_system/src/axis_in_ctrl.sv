// ***************
// Filename: axis_in_ctrl.sv
// Author: FPGA Cores 4 U
// Description: AXI4-Stream video slave of vision_system: writes a frame
//   into the frame store in raster order (address 0 at the tuser beat, then
//   +1 per beat: no multiply on the write side).
//   - s_axis.tready = capture_en && fb_wr_ready (the top's sequencer and the
//     store's write FIFO); gaps (tvalid low) anywhere are allowed.
//   - A frame starts at a tuser beat and ends at the tlast of its
//     IMG_HEIGHT-th line: frame_done pulses the clock after, the counters
//     return to row 0. Beats outside a frame (before a tuser) are consumed
//     and dropped, not written or counted.
//   - err_line_len (sticky diagnostic): a line's tlast came on a beat other
//     than IMG_WIDTH - 1 of that line; lines are counted by tlast.
//   - busy: inside a frame.
//   Clock - clk. Reset - synchronous active low rst_n (vision_system's
//   datapath reset, includes the CTRL soft reset). Clock-domain crossings
//   - none. Latency - a beat is written in the clock it is taken.
// Date: 2026-10-21

module axis_in_ctrl #(
  parameter int COORD_W = barrel_pkg::COORD_W,
  parameter int ADDR_W  = barrel_pkg::ADDR_W
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // control
  input  logic                    capture_en,    // top FSM: allowed to receive a frame
  input  logic                    fb_wr_ready,
  input  logic [COORD_W-1:0]      img_width,
  input  logic [COORD_W-1:0]      img_height,
  output logic                    frame_done,    // 1-cycle pulse: last pixel of frame written
  output logic                    busy,
  output logic                    err_line_len,  // sticky: a line didn't match img_width (diagnostic)

  // AXI4-Stream slave
  // s_axis: axis_if.slave (ip/shared/src/interfaces/axis_if.sv), DATA_W = barrel_pkg::PIX_W
  axis_if.slave s_axis,

  // frame_buffer write port
  output logic                    wr_en,
  output logic [ADDR_W-1:0]       wr_addr,
  output logic [barrel_pkg::PIX_W-1:0]        wr_data
);

  logic [ADDR_W-1:0]  addr_cnt;
  logic [COORD_W-1:0] col_cnt;
  logic [COORD_W-1:0] row_cnt;
  logic                active;   // mid-frame
  // the row / column of the beat in flight: a start-of-frame beat is row 0, column 0 whatever the
  // counters were left holding by the previous frame (a one-pixel-wide frame's first beat is also a line end)
  wire  [COORD_W-1:0] row_now = s_axis.tuser ? '0 : row_cnt;
  wire  [COORD_W-1:0] col_now = s_axis.tuser ? '0 : col_cnt;

  // beats are taken while capture_en; only a frame's beats (from its tuser on) are written and counted, so
  // a line arriving outside a frame (stream started mid-frame, a truncated frame) is consumed and dropped
  assign s_axis.tready = capture_en && fb_wr_ready;
  assign wr_en   = capture_en && s_axis.tvalid && s_axis.tready && (active || s_axis.tuser);
  // The tuser (first-pixel-of-frame) beat must always land at address 0,
  // regardless of whatever addr_cnt was left holding at the end of the
  // *previous* frame (addr_cnt is only guaranteed to already be 0 on the
  // very first frame after reset -- every subsequent frame needs this
  // explicit override, or its first pixel silently corrupts a stale
  // address instead of address 0).
  assign wr_addr = (wr_en && s_axis.tuser) ? '0 : addr_cnt;
  assign wr_data = s_axis.tdata;
  assign busy    = active;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      addr_cnt <= '0;
      col_cnt <= '0;
      row_cnt <= '0;
      active <= 1'b0;
      frame_done <= 1'b0;
      err_line_len <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      if (wr_en) begin
        if (s_axis.tuser) begin
          // start-of-frame: restart addressing regardless of prior state
          addr_cnt <= ADDR_W'(1);                     // this beat consumes address 0
          col_cnt  <= (img_width == COORD_W'(1)) ? '0 : COORD_W'(1);
          row_cnt  <= '0;
          active   <= 1'b1;
        end else begin
          addr_cnt <= addr_cnt + 1'b1;
          col_cnt  <= col_cnt + 1'b1;
        end

        if (s_axis.tlast) begin
          if (col_now != img_width - 1)
            err_line_len <= 1'b1;
          col_cnt <= '0;
          if (row_now == img_height - 1) begin
            frame_done <= 1'b1;
            active     <= 1'b0;
            row_cnt    <= '0;
          end else begin
            row_cnt <= row_now + 1'b1;
          end
        end
      end
    end
  end

endmodule
