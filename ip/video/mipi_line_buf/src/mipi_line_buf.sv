// ***************
// Filename: mipi_line_buf.sv
// Author: FPGA Cores 4 U
// Description: Dual-clock ping-pong line buffer for MIPI transmitters.
//   Version 1.0.0. The pixel clock side writes one video line into a free
//   buffer (pixels in raster order with px_valid_i, then a line_end_i pulse
//   at least one clock after the last pixel) and reports it with
//   line_ready_o (buffer, width). The byte clock side reads the line as
//   pixel pairs - word k = {pixel 2k+1, pixel 2k} in 48 bits, one clock of
//   read latency - and frees the buffer with done_i. A D-PHY HS burst cannot
//   pause, so a whole line is buffered before it is sent. With both buffers
//   in use, a new line is dropped and line_drop_o pulses. Clocks - pclk
//   (pixels) and bclk (D-PHY byte clock), unrelated; the free indications
//   cross through pulse_sync. Resets - synchronous per domain, active low;
//   assert both together.
// Date: 2026-10-02
module mipi_line_buf #(
  parameter int MAX_W = 2048                     // even
) (
  // Pixel side
  input  logic                         pclk,
  input  logic                         prst_n,
  input  logic [23:0]                  px_i,
  input  logic                         px_valid_i,
  input  logic                         line_end_i,
  output logic                         line_ready_o,
  output logic                         line_buf_o,
  output logic [15:0]                  line_width_o,
  output logic                         line_drop_o,
  // Byte side
  input  logic                         bclk,
  input  logic                         brst_n,
  input  logic                         rd_buf_i,
  input  logic [$clog2(MAX_W/2)-1:0]   rd_addr_i,
  output logic [47:0]                  rd_data_o,
  input  logic                         done_i
);
  localparam int AW = $clog2(MAX_W / 2);

  // ---------------- storage: buffer b at words b*MAX_W/2 ...
  logic [47:0] mem [2 * (MAX_W / 2)];
  logic        we; logic [AW:0] waddr; logic [47:0] wdata;
  always_ff @(posedge pclk) if (we) mem[waddr] <= wdata;
  always_ff @(posedge bclk) rd_data_o <= mem[{rd_buf_i, rd_addr_i}];

  // ---------------- buffer release (byte side -> pixel side)
  logic [1:0] freed;
  pulse_sync u_free0 (.src_clk(bclk), .src_rst_n(brst_n), .pulse_i(done_i && !rd_buf_i), .busy_o(), .drop_o(),
                      .dst_clk(pclk), .dst_rst_n(prst_n), .pulse_o(freed[0]));
  pulse_sync u_free1 (.src_clk(bclk), .src_rst_n(brst_n), .pulse_i(done_i &&  rd_buf_i), .busy_o(), .drop_o(),
                      .dst_clk(pclk), .dst_rst_n(prst_n), .pulse_o(freed[1]));

  // ---------------- pixel side
  logic [1:0] free; logic wb, in_line, dropping; logic [15:0] wp; logic [23:0] hold;
  wire  start = px_valid_i && !in_line;
  wire  use_b = free[wb] ? wb : ~wb;             // buffer for a new line
  wire  room  = free[wb] || free[~wb];
  wire  cur_b = start ? use_b : wb;
  wire  wr_px = px_valid_i && (start ? room : !dropping) && wp < 16'(MAX_W);

  always_comb begin
    we = 1'b0; waddr = {cur_b, wp[AW:1]}; wdata = {px_i, hold};
    if (wr_px && wp[0]) we = 1'b1;                                   // odd pixel completes a pair
    if (line_end_i && in_line && !dropping && wp[0]) begin             // odd width: last half pair
      we = 1'b1; waddr = {wb, wp[AW:1]}; wdata = {24'd0, hold};
    end
  end

  always_ff @(posedge pclk) begin
    if (!prst_n) begin
      free <= 2'b11; wb <= 1'b0; in_line <= 1'b0; dropping <= 1'b0; wp <= '0; hold <= '0;
      line_ready_o <= 1'b0; line_buf_o <= 1'b0; line_width_o <= '0; line_drop_o <= 1'b0;
    end else begin
      line_ready_o <= 1'b0; line_drop_o <= 1'b0;
      if (start) begin in_line <= 1'b1; dropping <= !room; wb <= use_b; end
      if (wr_px) begin
        if (!wp[0]) hold <= px_i;
        wp <= wp + 1'b1;
      end
      if (line_end_i && in_line) begin
        if (dropping) line_drop_o <= 1'b1;
        else if (wp != 0) begin
          line_ready_o <= 1'b1; line_buf_o <= wb; line_width_o <= wp;
        end
        in_line <= 1'b0; dropping <= 1'b0; wp <= '0;
      end
      // a buffer becomes busy when its line is reported, free again when released
      for (int b = 0; b < 2; b++) begin
        if (line_end_i && in_line && !dropping && wp != 0 && wb == 1'(b)) free[b] <= 1'b0;
        else if (freed[b]) free[b] <= 1'b1;
      end
      if (line_end_i && in_line && !dropping && wp != 0) wb <= ~wb;
    end
  end
endmodule
