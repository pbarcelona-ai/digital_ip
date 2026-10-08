// ***************
// Filename: tmds_serializer.sv
// Author: FPGA Cores 4 U
// Description: Generic 10:1 TMDS serializer (behavioural, technology
//   independent). Version 1.0.0. Shifts the three channel symbols and the
//   clock pattern out LSB first on ser_clk, which must be exactly 10x the
//   pixel clock and come from the same PLL / MMCM. A toggle written every
//   pixel clock is synchronised into ser_clk; three ser_clk cycles after
//   each toggle edge the symbols (stable for the whole pixel period) are
//   loaded, so the result does not depend on the phase between the clocks.
//   Use this for simulation, for slow links, or on devices with fast
//   general fabric; at 1080p60 (1.485 Gbit/s per lane) replace it with the
//   vendor serializer (e.g. two cascaded OSERDESE2 in 10:1 DDR mode with a
//   5x clock) and differential output buffers (OBUFDS / TMDS_33 I/O).
//   Clocks - pix_clk and ser_clk = 10 x pix_clk, related. Reset -
//   synchronous per domain, active low. Latency - about 2 pixel clocks.
// Date: 2026-10-01
module tmds_serializer (
  input  logic       pix_clk,
  input  logic       pix_rst_n,
  input  logic [9:0] tmds0_i,
  input  logic [9:0] tmds1_i,
  input  logic [9:0] tmds2_i,
  input  logic [9:0] tmds_clk_i,
  input  logic       ser_clk,
  input  logic       ser_rst_n,
  output logic [3:0] serial_o                   // {clock, ch2, ch1, ch0}
);
  // Pixel domain: hold the symbols for a whole pixel period, mark each one
  logic [39:0] sym_q; logic tog;
  always_ff @(posedge pix_clk) begin
    if (!pix_rst_n) begin sym_q <= '0; tog <= 1'b0; end
    else begin sym_q <= {tmds_clk_i, tmds2_i, tmds1_i, tmds0_i}; tog <= ~tog; end
  end

  // Serial domain
  (* async_reg = "true" *) logic t1, t2;
  logic t3; logic [3:0] dly; logic [9:0] sh [4];
  always_ff @(posedge ser_clk) begin
    if (!ser_rst_n) begin
      t1 <= 1'b0; t2 <= 1'b0; t3 <= 1'b0; dly <= '0;
      for (int c = 0; c < 4; c++) sh[c] <= '0;
      serial_o <= '0;
    end else begin
      t1 <= tog; t2 <= t1; t3 <= t2;
      dly <= {dly[2:0], t2 ^ t3};                      // edge seen; wait for the data to settle
      for (int c = 0; c < 4; c++) begin
        if (dly[0]) sh[c] <= sym_q[10*c +: 10];        // new symbol: bit 0 goes out next
        else        sh[c] <= {1'b0, sh[c][9:1]};
        serial_o[c] <= dly[0] ? sym_q[10*c] : sh[c][1];
      end
    end
  end
endmodule
