// ***************
// Filename: tmds_encoder_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for tmds_encoder. Video mode: 200000
//   random and corner-case bytes in runs separated by control periods
//   (which must reset the disparity), compared with a model of the DVI 1.0
//   encoding flowchart, decoded back to the input byte, and the running DC
//   balance of the transmitted bits checked to stay within +/-10. Control,
//   TERC4 (all 16 codes distinct, none a control token) and guard band
//   symbols are checked against the HDMI tables. Prints TEST PASSED on
//   success.
// Date: 2026-10-01
`timescale 1ns/1ps
module tmds_encoder_tb;
  logic clk = 0, rst_n = 0; always #5 clk = ~clk;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  logic [1:0] mode, c; logic [7:0] d; logic [3:0] t; logic [9:0] g, q;
  tmds_encoder dut (.clk, .rst_n, .mode_i(mode), .d_i(d), .c_i(c), .t_i(t), .g_i(g), .q_o(q));

  // DVI 1.0 encoder model (spec flowchart)
  int mcnt = 0;
  function automatic logic [9:0] model(input logic [7:0] din);
    int n1, n1q; logic [8:0] qm; logic [9:0] o;
    n1 = $countones(din); qm[0] = din[0];
    if (n1 > 4 || (n1 == 4 && !din[0])) begin for (int i = 1; i < 8; i++) qm[i] = qm[i-1] ~^ din[i]; qm[8] = 0; end
    else begin for (int i = 1; i < 8; i++) qm[i] = qm[i-1] ^ din[i]; qm[8] = 1; end
    n1q = $countones(qm[7:0]);
    if (mcnt == 0 || n1q == 4) begin
      o[9] = ~qm[8]; o[8] = qm[8]; o[7:0] = qm[8] ? qm[7:0] : ~qm[7:0];
      mcnt += qm[8] ? (n1q - (8 - n1q)) : ((8 - n1q) - n1q);
    end else if ((mcnt > 0 && n1q > 4) || (mcnt < 0 && n1q < 4)) begin
      o = {1'b1, qm[8], ~qm[7:0]}; mcnt += 2 * qm[8] + ((8 - n1q) - n1q);
    end else begin
      o = {1'b0, qm[8], qm[7:0]}; mcnt += -2 * (!qm[8]) + (n1q - (8 - n1q));
    end
    return o;
  endfunction
  function automatic logic [7:0] decode(input logic [9:0] s);
    logic [7:0] m, o; m = s[9] ? ~s[7:0] : s[7:0]; o[0] = m[0];
    for (int i = 1; i < 8; i++) o[i] = s[8] ? m[i] ^ m[i-1] : m[i] ~^ m[i-1];
    return o;
  endfunction

  localparam logic [9:0] CTRL [4] = '{10'b1101010100, 10'b0010101011, 10'b0101010100, 10'b1010101011};
  localparam logic [9:0] TERC [16] = '{10'b1010011100, 10'b1001100011, 10'b1011100100, 10'b1011100010,
    10'b0101110001, 10'b0100011110, 10'b0110001110, 10'b0100111100, 10'b1011001100, 10'b0100111001,
    10'b0110011100, 10'b1011000110, 10'b1010001110, 10'b1001110001, 10'b0101100011, 10'b1011000011};

  initial begin
    int disp, maxdisp, nv;
    if ($test$plusargs("vcd")) begin $dumpfile("tmds_encoder_tb.vcd"); $dumpvars(0, tmds_encoder_tb); end
    mode = 0; c = 0; d = 0; t = 0; g = 0;
    repeat (3) @(posedge clk); rst_n = 1; @(posedge clk);
    // ---- video runs
    disp = 0; maxdisp = 0; nv = 0;
    while (nv < 200000) begin
      int run; run = 1 + $urandom_range(2000);
      mcnt = 0; disp = 0;
      for (int i = 0; i < run; i++) begin
        logic [9:0] e; logic [7:0] v;
        case ($urandom_range(5))
          0: v = 8'h00; 1: v = 8'hFF; 2: v = 8'h55; default: v = $urandom_range(255);
        endcase
        mode <= 1; d <= v; @(posedge clk); #1;
        e = model(v);
        check(q == e, $sformatf("video %02h: %b exp %b", v, q, e));
        check(decode(q) == v, $sformatf("video %02h decodes to %02h", v, decode(q)));
        disp += 2 * $countones(q) - 10;
        if (disp > maxdisp) maxdisp = disp; if (-disp > maxdisp) maxdisp = -disp;
        nv++;
      end
      mode <= 0; c <= $urandom_range(3); @(posedge clk); #1;   // control period resets the disparity
    end
    check(maxdisp <= 10, $sformatf("running disparity reached %0d", maxdisp));
    $display("video: %0d symbols, max running disparity %0d", nv, maxdisp);
    // ---- control tokens
    for (int k = 0; k < 4; k++) begin mode <= 0; c <= k; @(posedge clk); #1; check(q == CTRL[k], $sformatf("control %0d = %b", k, q)); end
    // ---- TERC4: table, distinct, not control tokens
    for (int k = 0; k < 16; k++) begin
      mode <= 2; t <= k; @(posedge clk); #1;
      check(q == TERC[k], $sformatf("TERC4 %0d = %b", k, q));
      for (int j = 0; j < 4; j++) check(q != CTRL[j], $sformatf("TERC4 %0d equals a control token", k));
      for (int j = 0; j < k; j++) check(TERC[j] != TERC[k], $sformatf("TERC4 %0d and %0d identical", j, k));
    end
    // ---- guard band passes through
    mode <= 3; g <= 10'b0100110011; @(posedge clk); #1; check(q == 10'b0100110011, "guard band symbol");
    $display("control, TERC4 and guard band symbols checked");
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
