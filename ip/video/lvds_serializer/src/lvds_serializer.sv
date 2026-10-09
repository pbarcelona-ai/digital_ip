// ***************
// Filename: lvds_serializer.sv
// Author: FPGA Cores 4 U
// Description: Generic 7:1 LVDS serializer (behavioural, technology
//   independent). Version 1.0.0. Shifts NL 7-bit words out MSB (bit 6)
//   first on ser_clk, which must be exactly 7x the word rate (7x the pixel
//   clock for single link, 3.5x for dual link with stb_i on alternate pixel
//   clocks) and come from the same PLL / MMCM. A toggle written with every
//   word (stb_i) is synchronised into ser_clk and the word, stable for the
//   whole word period, is loaded a few ser_clk cycles after each toggle
//   edge, so the result does not depend on the phase between the clocks.
//   Put the clock lane in one of the NL lanes (word 1100011). For high
//   resolutions use the vendor serializer (OSERDESE2 in 7:1 mode or an
//   ISERDES/OSERDES based 7:1 design) and LVDS output buffers.
//   Clocks - pix_clk, ser_clk (related). Resets - synchronous per domain,
//   active low. Latency - about 2 word periods.
// Date: 2026-10-02
module lvds_serializer #(
  parameter int NL = 5                           // lanes (data lanes + clock lane)
) (
  input  logic          pix_clk,
  input  logic          pix_rst_n,
  input  logic [NL*7-1:0] words_i,               // lane i in [7i +: 7]
  input  logic          stb_i,
  input  logic          ser_clk,
  input  logic          ser_rst_n,
  output logic [NL-1:0] serial_o
);
  logic [NL*7-1:0] w_q;
  logic tog;
  always_ff @(posedge pix_clk) begin
    if (!pix_rst_n) begin
      w_q <= '0;
      tog <= 1'b0;
    end
    else if (stb_i) begin
      w_q <= words_i;
      tog <= ~tog;
    end
  end

  (* async_reg = "true" *) logic t1, t2;
  logic t3;
  logic [1:0] dly;
  logic [6:0] sh [NL];
  always_ff @(posedge ser_clk) begin
    if (!ser_rst_n) begin
      t1 <= 1'b0;
      t2 <= 1'b0;
      t3 <= 1'b0;
      dly <= '0;
      serial_o <= '0;
      for (int c = 0; c < NL; c++) sh[c] <= '0;
    end else begin
      t1 <= tog;
      t2 <= t1;
      t3 <= t2;
      dly <= {dly[0], t2 ^ t3};
      for (int c = 0; c < NL; c++) begin
        if (dly[0]) begin // bit 6 first
          sh[c] <= {w_q[7*c +: 6], 1'b0};
          serial_o[c] <= w_q[7*c + 6];
        end
        else begin
          sh[c] <= {sh[c][5:0], 1'b0};
          serial_o[c] <= sh[c][6];
        end
      end
    end
  end
endmodule
