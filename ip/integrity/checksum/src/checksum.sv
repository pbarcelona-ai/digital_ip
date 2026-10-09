// ***************
// Filename: checksum.sv
// Author: FPGA Cores 4 U
// Description: Configurable byte-stream checksum. Version 1.0.0. MODE 0 is
//   an 8-bit two's-complement sum (the sum of all bytes plus the checksum
//   is 0 mod 256), MODE 1 is the RFC 1071 Internet checksum (16-bit one's
//   complement sum of big-endian byte pairs, inverted; an odd final byte
//   is padded with zero), MODE 2 is Fletcher-16 (two running sums modulo
//   255). One byte is consumed per clock when valid_i is high; init_i
//   clears the state. checksum_o always reflects the bytes consumed so far
//   (a pending odd Internet byte is padded on the fly), so no flush is
//   needed. ok_o is high when the stream seen so far includes its own
//   checksum and the total verifies (Internet result 0xFFFF sum / SUM8
//   zero / Fletcher-16 both sums zero). Clock - clk. Reset - synchronous
//   active low, empty state. Latency - checksum_o valid 1 clock after the
//   last byte. Errors - MODE outside 0..2 rejected at elaboration.
// Date: 2026-09-29
module checksum #(
  parameter int MODE = 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        init_i,
  input  logic        valid_i,
  input  logic [7:0]  byte_i,
  output logic [15:0] checksum_o,
  output logic        ok_o
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  if (MODE < 0 || MODE > 2) begin : g_bm $error("checksum: MODE must be 0..2"); end
  logic [7:0]  s8, hold;
  logic [7:0] f1, f2;
  logic [16:0] s16;
  logic odd;
  function automatic logic [15:0] fold(input logic [17:0] x);
    logic [17:0] y;
    y = {2'b0, x[15:0]} + {16'b0, x[17:16]};
    y = {2'b0, y[15:0]} + {16'b0, y[17:16]};
    fold = y[15:0];
  endfunction
  // Fletcher-16 next state (combinational, modulo 255 by conditional subtract)
  wire [8:0] n1_raw = {1'b0, f1} + {1'b0, byte_i};
  wire [8:0] n1     = (n1_raw >= 9'd255) ? (n1_raw - 9'd255) : n1_raw;
  wire [9:0] n2_raw = {2'b0, f2} + {1'b0, n1};
  wire [9:0] n2     = (n2_raw >= 10'd255) ? (n2_raw - 10'd255) : n2_raw;
  wire [15:0] ones_sum = fold({1'b0, s16} + (odd ? {9'b0, hold} << 8 : 18'd0));
  always_ff @(posedge clk) begin
    if (!rst_n || init_i) begin
      s8 <= '0;
      hold <= '0;
      f1 <= '0;
      f2 <= '0;
      s16 <= '0;
      odd <= 1'b0;
    end
    else if (valid_i) begin
      s8 <= s8 + byte_i;
      f1 <= n1[7:0];
      f2 <= n2[7:0];
      if (!odd) begin
        hold <= byte_i;
        odd <= 1'b1;
      end
      else begin
        s16 <= {1'b0, fold({1'b0, s16} + {2'b0, hold, byte_i})};
        odd <= 1'b0;
      end
    end
  end
  always_comb begin
    case (MODE)
      0: begin
        checksum_o = {8'h00, 8'(-s8)};
        ok_o = (s8 == 8'h00);
      end
      1: begin
        checksum_o = ~ones_sum;
        ok_o = (ones_sum == 16'hFFFF);
      end
      default: begin
        checksum_o = {f2, f1};
        ok_o = (f1 == 8'h00) && (f2 == 8'h00);
      end
    endcase
  end
endmodule
