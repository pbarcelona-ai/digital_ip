// ***************
// Filename: cordic.sv
// Author: FPGA Cores 4 U
// Description: Pipelined CORDIC. Version 1.0.0. MODE 0 (rotation) rotates the
//   vector (x_i, y_i) by the angle z_i, giving x*cos-y*sin and x*sin+y*cos
//   (with x_i=A, y_i=0 it is a sine/cosine generator of amplitude A); MODE 1
//   (vectoring) returns the magnitude sqrt(x^2+y^2) in mag_o and the angle
//   atan2(y,x) in z_o. Angles are unsigned turns - z is ZW bits and 2^ZW
//   equals 2*pi, so the phase word of an NCO connects directly. Full-circle
//   range is handled by a quadrant pre-rotation, the CORDIC gain (1.6468) is
//   compensated by a constant multiplier, and WIDTH+2 guard bits are used
//   internally. One result per clock (fully pipelined), ITER micro-rotations.
//   Clock - clk with valid_i/valid_o. Reset - synchronous active low clears
//   the valid pipeline (data registers are unreset, valid_o=0 masks them).
//   Latency - ITER+2 clocks. Accuracy - about 2 LSB in rotation mode and 2
//   LSB plus 2^-ITER rad in vectoring mode; inputs must satisfy |(x,y)| <=
//   2^(WIDTH-1)-1 (rotation) so results fit; magnitude output has WIDTH+1
//   bits. Errors - out-of-range parameters rejected at elaboration.
// Date: 2026-09-29
module cordic #(
  parameter int WIDTH = 16,             // x, y width (signed)
  parameter int ZW    = 16,             // angle width (unsigned turns)
  parameter int ITER  = 16,             // micro-rotations (<= 30)
  parameter int MODE  = 0               // 0 rotation, 1 vectoring
) (
  input  logic                     clk,
  input  logic                     rst_n,
  input  logic                     valid_i,
  input  logic signed [WIDTH-1:0]  x_i,
  input  logic signed [WIDTH-1:0]  y_i,
  input  logic        [ZW-1:0]     z_i,          // rotation angle (MODE 0)
  output logic                     valid_o,
  output logic signed [WIDTH-1:0]  x_o,          // MODE 0: rotated x
  output logic signed [WIDTH-1:0]  y_o,          // MODE 0: rotated y
  output logic        [WIDTH:0]    mag_o,        // MODE 1: magnitude
  output logic        [ZW-1:0]     z_o           // MODE 1: angle in turns
);
  localparam logic [31:0] IP_VERSION = 32'h0001_0000;
  localparam int GUARD = 3;
  localparam int ZX    = 4;                 // extra angle bits used internally
  localparam int ZA    = ZW + ZX;
  localparam int IW    = WIDTH + GUARD + 1;
  if (WIDTH < 4 || WIDTH > 30) begin : g_bw $error("cordic: WIDTH must be 4..30"); end
  if (ZW < 6 || ZW > 28) begin : g_bz $error("cordic: ZW must be 6..28"); end
  if (ITER < 2 || ITER > 30) begin : g_bi $error("cordic: ITER must be 2..30"); end
  if (MODE < 0 || MODE > 1) begin : g_bm $error("cordic: MODE must be 0 or 1"); end
  localparam logic [16:0] KINV = 17'd39797;       // 1/1.64676 in Q16

  function automatic logic [ZA-1:0] atan_tab(input logic [4:0] i);
    logic [31:0] v;
    case (i)
      5'd0: v = 32'h20000000;
      5'd1: v = 32'h12E4051E;
      5'd2: v = 32'h09FB385B;
      5'd3: v = 32'h051111D4;
      5'd4: v = 32'h028B0D43;
      5'd5: v = 32'h0145D7E1;
      5'd6: v = 32'h00A2F61E;
      5'd7: v = 32'h00517C55;
      5'd8: v = 32'h0028BE53;
      5'd9: v = 32'h00145F2F;
      5'd10: v = 32'h000A2F98;
      5'd11: v = 32'h000517CC;
      5'd12: v = 32'h00028BE6;
      5'd13: v = 32'h000145F3;
      5'd14: v = 32'h0000A2FA;
      5'd15: v = 32'h0000517D;
      5'd16: v = 32'h000028BE;
      5'd17: v = 32'h0000145F;
      5'd18: v = 32'h00000A30;
      5'd19: v = 32'h00000518;
      5'd20: v = 32'h0000028C;
      5'd21: v = 32'h00000146;
      5'd22: v = 32'h000000A3;
      5'd23: v = 32'h00000051;
      5'd24: v = 32'h00000029;
      5'd25: v = 32'h00000014;
      5'd26: v = 32'h0000000A;
      5'd27: v = 32'h00000005;
      5'd28: v = 32'h00000003;
      5'd29: v = 32'h00000001;
      5'd30: v = 32'h00000001;
      5'd31: v = 32'h00000000;
      default: v = 32'h0;
    endcase
    atan_tab = (v + (32'd1 << (31 - ZA))) >> (32 - ZA);
  endfunction

  // ---------------- stage 0: fold and gain ----------------
  logic signed [IW-1:0] xs [0:ITER];
  logic signed [IW-1:0] ys [0:ITER];
  logic        [ZA-1:0] zs [0:ITER];
  logic                 vs [0:ITER];
  logic signed [IW-1:0] xe, ye, xf, yf; logic [ZA-1:0] zf;
  logic signed [IW+17:0] xm, ym;
  always_comb begin
    xe = IW'(x_i) <<< GUARD; ye = IW'(y_i) <<< GUARD; xf = xe; yf = ye; zf = '0;
    if (MODE == 0) begin
      case (z_i[ZW-1:ZW-2])
        2'd0: begin xf = xe;  yf = ye;  end
        2'd1: begin xf = -ye; yf = xe;  end
        2'd2: begin xf = -xe; yf = -ye; end
        default: begin xf = ye; yf = -xe; end
      endcase
      zf = {2'b00, z_i[ZW-3:0], {ZX{1'b0}}};
    end else begin
      if (xe < 0) begin xf = -xe; yf = -ye; zf = {1'b1, {(ZA-1){1'b0}}}; end
    end
    xm = xf * $signed({1'b0, KINV});
    ym = yf * $signed({1'b0, KINV});
  end
  always_ff @(posedge clk) begin
    if (!rst_n) vs[0] <= 1'b0; else vs[0] <= valid_i;
    if (MODE == 0) begin xs[0] <= xm >>> 16; ys[0] <= ym >>> 16; end
    else begin xs[0] <= xf; ys[0] <= yf; end
    zs[0] <= zf;
  end
  // ---------------- iterations ----------------
  for (genvar i = 0; i < ITER; i++) begin : g_it
    // rotation: d = +1 when z >= 0. vectoring: d = +1 when y < 0
    wire dpos = (MODE == 0) ? ~zs[i][ZA-1] : ys[i][IW-1];
    wire signed [IW-1:0] xsh = xs[i] >>> i;
    wire signed [IW-1:0] ysh = ys[i] >>> i;
    wire [ZA-1:0] at = atan_tab(5'(i));
    always_ff @(posedge clk) begin
      if (!rst_n) vs[i+1] <= 1'b0; else vs[i+1] <= vs[i];
      if (dpos) begin xs[i+1] <= xs[i] - ysh; ys[i+1] <= ys[i] + xsh; zs[i+1] <= zs[i] - at; end
      else      begin xs[i+1] <= xs[i] + ysh; ys[i+1] <= ys[i] - xsh; zs[i+1] <= zs[i] + at; end
    end
  end
  // ---------------- output stage ----------------
  localparam logic signed [IW-1:0] RND = (1 <<< (GUARD - 1));
  logic signed [IW-1:0] xr, yr; logic signed [IW+17:0] mm;
  logic signed [WIDTH-1:0] maxv, minv;
  assign maxv = {1'b0, {(WIDTH-1){1'b1}}}; assign minv = {1'b1, {(WIDTH-1){1'b0}}};
  always_comb begin
    xr = (xs[ITER] + RND) >>> GUARD; yr = (ys[ITER] + RND) >>> GUARD;
    mm = xs[ITER] * $signed({1'b0, KINV});
  end
  logic signed [IW+17:0] mmr;
  always_comb mmr = (mm + (1 <<< (16 + GUARD - 1))) >>> (16 + GUARD);
  always_ff @(posedge clk) begin
    if (!rst_n) valid_o <= 1'b0; else valid_o <= vs[ITER];
    if (MODE == 0) begin
      x_o <= (xr > IW'(maxv)) ? maxv : (xr < IW'(minv)) ? minv : xr[WIDTH-1:0];
      y_o <= (yr > IW'(maxv)) ? maxv : (yr < IW'(minv)) ? minv : yr[WIDTH-1:0];
      mag_o <= '0; z_o <= '0;
    end else begin
      mag_o <= (mmr < 0) ? '0 : mmr[WIDTH:0];
      z_o   <= (zs[ITER] + (1 << (ZX - 1))) >> ZX; x_o <= '0; y_o <= '0;
    end
  end
endmodule
