// ***************
// Filename: tmds_encoder.sv
// Author: FPGA Cores 4 U
// Description: TMDS encoder for one DVI / HDMI channel. Version 1.0.0.
//   mode_i selects the symbol of each pixel clock:
//     0 CONTROL - c_i = {C1, C0} -> one of the four control tokens
//     1 VIDEO   - d_i, 8b/10b transition-minimised, DC-balanced coding of
//                 the DVI 1.0 specification (running disparity kept here)
//     2 TERC4   - t_i -> HDMI TERC4 symbol (data island payload)
//     3 GUARD   - g_i is sent as is (HDMI guard band symbol)
//   The running disparity is cleared in every non-video period, as the
//   specification requires. q_o[0] is the first bit on the wire. Clock -
//   pixel clock only. Reset - synchronous rst_n (active low). Latency -
//   1 clock (registered output).
// Date: 2026-10-01
module tmds_encoder (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [1:0] mode_i,
  input  logic [7:0] d_i,
  input  logic [1:0] c_i,
  input  logic [3:0] t_i,
  input  logic [9:0] g_i,
  output logic [9:0] q_o
);
  localparam logic [1:0] M_CTRL = 2'd0, M_VIDEO = 2'd1, M_TERC4 = 2'd2, M_GUARD = 2'd3;

  // ---------------- 8b/10b video coding (DVI 1.0, section 3.2.2)
  logic [3:0] n1d, n1q;
  logic [8:0] qm;
  logic [9:0] qv;
  logic signed [5:0] cnt, cnt_n;
  always_comb begin
    logic [8:0] t;                               // transition-minimised word, built bit by bit
    n1d = 4'($countones(d_i));
    t = '0;
    t[0] = d_i[0];
    if (n1d > 4 || (n1d == 4 && d_i[0] == 1'b0)) begin
      for (int i = 1; i < 8; i++) t[i] = ~(t[i-1] ^ d_i[i]);
      t[8] = 1'b0;
    end else begin
      for (int i = 1; i < 8; i++) t[i] = t[i-1] ^ d_i[i];
      t[8] = 1'b1;
    end
    qm = t;
    n1q = 4'($countones(qm[7:0]));
    if (cnt == 0 || n1q == 4'd4) begin
      qv = {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
      cnt_n = qm[8] ? cnt + (6'(n1q) - 6'(4'd8 - n1q)) : cnt + (6'(4'd8 - n1q) - 6'(n1q));
    end else if ((cnt > 0 && n1q > 4'd4) || (cnt < 0 && n1q < 4'd4)) begin
      qv = {1'b1, qm[8], ~qm[7:0]};
      cnt_n = cnt + 6'({qm[8], 1'b0}) + (6'(4'd8 - n1q) - 6'(n1q));
    end else begin
      qv = {1'b0, qm[8], qm[7:0]};
      cnt_n = cnt - 6'({~qm[8], 1'b0}) + (6'(n1q) - 6'(4'd8 - n1q));
    end
  end

  // ---------------- fixed symbols
  function automatic logic [9:0] ctrl_sym(input logic [1:0] c);
    case (c)
      2'b00:   ctrl_sym = 10'b1101010100;
      2'b01:   ctrl_sym = 10'b0010101011;
      2'b10:   ctrl_sym = 10'b0101010100;
      default: ctrl_sym = 10'b1010101011;
    endcase
  endfunction
  function automatic logic [9:0] terc4_sym(input logic [3:0] t);
    case (t)
      4'h0: terc4_sym = 10'b1010011100;
      4'h1: terc4_sym = 10'b1001100011;
      4'h2: terc4_sym = 10'b1011100100;
      4'h3: terc4_sym = 10'b1011100010;
      4'h4: terc4_sym = 10'b0101110001;
      4'h5: terc4_sym = 10'b0100011110;
      4'h6: terc4_sym = 10'b0110001110;
      4'h7: terc4_sym = 10'b0100111100;
      4'h8: terc4_sym = 10'b1011001100;
      4'h9: terc4_sym = 10'b0100111001;
      4'hA: terc4_sym = 10'b0110011100;
      4'hB: terc4_sym = 10'b1011000110;
      4'hC: terc4_sym = 10'b1010001110;
      4'hD: terc4_sym = 10'b1001110001;
      4'hE: terc4_sym = 10'b0101100011;
      default: terc4_sym = 10'b1011000011;
    endcase
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      q_o <= ctrl_sym(2'b00);
      cnt <= '0;
    end else begin
      case (mode_i)
        M_VIDEO: begin
          q_o <= qv;
          cnt <= cnt_n;
        end
        M_TERC4: begin
          q_o <= terc4_sym(t_i);
          cnt <= '0;
        end
        M_GUARD: begin
          q_o <= g_i;
          cnt <= '0;
        end
        default: begin
          q_o <= ctrl_sym(c_i);
          cnt <= '0;
        end
      endcase
    end
  end
endmodule
