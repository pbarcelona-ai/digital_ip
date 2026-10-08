// ***************
// Filename: axis_frame_bfm.sv
// Author: FPGA Cores 4 U
// Description: Testbench AXI4-Stream video frame driver and monitor.
//   send(W, H) streams img[][] as one frame (tuser on the first pixel,
//   tlast at each line end) with gap_pct % random idle cycles; the monitor
//   applies bp_pct % random back-pressure, stores the output frame in out[][]
//   (frame size ow x oh, set by the testbench), checks tuser / tlast
//   positions, counts complete frames in frames and protocol errors in
//   errors. in_sof_t / out_sof_t hold the time of the last start-of-frame
//   handshake on each side (for latency checks).
// Date: 2026-10-08
`timescale 1ns/1ps
module axis_frame_bfm #(
  parameter int DW   = 24,
  parameter int MAXW = 64,
  parameter int MAXH = 64
) (
  input  logic          clk,
  output logic [DW-1:0] s_tdata,
  output logic          s_tlast,
  output logic          s_tuser,
  output logic          s_tvalid,
  input  logic          s_tready,
  input  logic [DW-1:0] m_tdata,
  input  logic          m_tlast,
  input  logic          m_tuser,
  input  logic          m_tvalid,
  output logic          m_tready
);
  logic [DW-1:0] img [MAXH][MAXW];
  logic [DW-1:0] out [MAXH][MAXW];
  int gap_pct = 0, bp_pct = 0, ow = 0, oh = 0, frames = 0, errors = 0, ox = 0, oy = 0, sent = 0;
  bit fdone = 1;                                  // the last frame was complete
  realtime in_sof_t = 0, out_sof_t = 0;
  initial begin s_tvalid = 0; s_tdata = '0; s_tlast = 0; s_tuser = 0; m_tready = 0; end

  task automatic send(input int W, input int H);
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) begin
        while (gap_pct != 0 && $urandom_range(99) < gap_pct) begin s_tvalid <= 1'b0; @(posedge clk); end
        s_tdata <= img[y][x]; s_tuser <= (x == 0 && y == 0); s_tlast <= (x == W - 1); s_tvalid <= 1'b1;
        @(posedge clk);
        while (!s_tready) @(posedge clk);
        if (x == 0 && y == 0) in_sof_t = $realtime;
        sent++;
      end
    s_tvalid <= 1'b0;
  endtask

  always @(posedge clk) begin
    if (m_tvalid && m_tready) begin
      if (m_tuser) begin
        if (ox != 0 || (oy != 0 && !fdone)) begin errors++; $display("ERROR @%0t: SOF at (%0d,%0d)", $time, ox, oy); end
        ox = 0; oy = 0; fdone = 0; out_sof_t = $realtime;
      end else if (ox == 0 && oy == 0) begin errors++; $display("ERROR @%0t: first pixel without tuser", $time); end
      if (m_tlast != (ox == ow - 1)) begin errors++; $display("ERROR @%0t: tlast %0b at x=%0d (width %0d)", $time, m_tlast, ox, ow); end
      if (oy < MAXH && ox < MAXW) out[oy][ox] = m_tdata;
      if (m_tlast) begin ox = 0; oy++; if (oy == oh) begin frames++; fdone = 1; end end
      else ox++;
    end
    m_tready <= ($urandom_range(99) >= bp_pct);
  end
endmodule
