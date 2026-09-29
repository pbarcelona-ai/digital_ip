// ***************
// Filename: axis_in_ctrl.sv
// Author: Paul Barcelona
// Description: AXI4-Stream video slave. Writes incoming pixels into
// the on-chip frame_buffer at a free-running raster address,
// enforcing the line-then-idle-gap timing and detecting the
// tuser start-of-frame marker and the bug-#4 back-to-back
// frame address reset.
// Date: September 26, 2026
// ***************
// =============================================================================
// axis_in_ctrl.sv
//
// AXI4-Stream (video) slave. Per the spec: each line is transferred as
// IMG_WIDTH back-to-back beats (tvalid held high, tlast on the final
// pixel of the line), followed by >=5 idle cycles (tvalid low) before the
// next line. tuser marks the first pixel of the frame (start-of-frame).
//
// Because lines are transferred with no gaps *within* a line, and the
// frame is stored in raster order, the write address is simply a
// free-running counter (no multiply needed on the write side).
// =============================================================================

module axis_in_ctrl #(
  parameter int COORD_W = barrel_pkg::COORD_W,
  parameter int ADDR_W  = barrel_pkg::ADDR_W
) (
  input  logic                    clk,
  input  logic                    rst_n,

  // control
  input  logic                    capture_en,    // top FSM: allowed to receive a frame
  input  logic [COORD_W-1:0]      img_width,
  input  logic [COORD_W-1:0]      img_height,
  output logic                    frame_done,    // 1-cycle pulse: last pixel of frame written
  output logic                    busy,
  output logic                    err_line_len,  // sticky: a line didn't match img_width (diagnostic)

  // AXI4-Stream slave
  input  logic                    s_axis_tvalid,
  output logic                    s_axis_tready,
  input  logic [barrel_pkg::PIX_W-1:0]        s_axis_tdata,
  input  logic                    s_axis_tlast,
  input  logic                    s_axis_tuser,

  // frame_buffer write port
  output logic                    wr_en,
  output logic [ADDR_W-1:0]       wr_addr,
  output logic [barrel_pkg::PIX_W-1:0]        wr_data
);

  logic [ADDR_W-1:0]  addr_cnt;
  logic [COORD_W-1:0] col_cnt;
  logic [COORD_W-1:0] row_cnt;
  logic                active;   // mid-frame

  assign s_axis_tready = capture_en;
  assign wr_en   = capture_en && s_axis_tvalid && s_axis_tready;
  // The tuser (first-pixel-of-frame) beat must always land at address 0,
  // regardless of whatever addr_cnt was left holding at the end of the
  // *previous* frame (addr_cnt is only guaranteed to already be 0 on the
  // very first frame after reset -- every subsequent frame needs this
  // explicit override, or its first pixel silently corrupts a stale
  // address instead of address 0).
  assign wr_addr = (wr_en && s_axis_tuser) ? '0 : addr_cnt;
  assign wr_data = s_axis_tdata;
  assign busy    = active;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      addr_cnt <= '0; col_cnt <= '0; row_cnt <= '0;
      active <= 1'b0; frame_done <= 1'b0; err_line_len <= 1'b0;
    end else begin
      frame_done <= 1'b0;
      if (wr_en) begin
        if (s_axis_tuser) begin
          // start-of-frame: restart addressing regardless of prior state
          addr_cnt <= 1'b1; // this beat consumes address 0
          col_cnt  <= (img_width == 1) ? '0 : 1'b1;
          row_cnt  <= '0;
          active   <= 1'b1;
        end else begin
          addr_cnt <= addr_cnt + 1'b1;
          col_cnt  <= col_cnt + 1'b1;
        end

        if (s_axis_tlast) begin
          if (!s_axis_tuser && (col_cnt != img_width - 1))
            err_line_len <= 1'b1;
          col_cnt <= '0;
          if (row_cnt == img_height - 1) begin
            frame_done <= 1'b1;
            active     <= 1'b0;
          end else begin
            row_cnt <= row_cnt + 1'b1;
          end
        end
      end
    end
  end

endmodule
