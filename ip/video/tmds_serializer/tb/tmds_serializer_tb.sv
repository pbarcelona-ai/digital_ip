// ***************
// Filename: tmds_serializer_tb.sv
// Author: FPGA Cores 4 U
// Description: Self-checking testbench for tmds_serializer. Pixel clock
//   10 ns, serial clock 1 ns, with the serial clock shifted by three
//   different amounts between runs. Random symbols are sent on the three channels; the serial
//   streams are cut into 10-bit words aligned on the clock channel pattern
//   (0000011111, sent LSB first) and every recovered symbol must equal the
//   one sent, in order. Prints TEST PASSED on success.
// Date: 2026-10-01
`timescale 1ns/1ps
module tmds_serializer_tb;
  int errors = 0;
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

  real shift_req = 0.0;                          // extra delay inserted once: moves the serial phase
  logic pix_clk = 0, ser_clk = 0, prst_n = 0, srst_n = 0;
  always #5 pix_clk = ~pix_clk;
  initial forever begin
    if (shift_req > 0.0) begin #(shift_req); shift_req = 0.0; end
    #0.5 ser_clk = ~ser_clk;
  end

  logic [9:0] s0, s1, s2; logic [3:0] ser;
  tmds_serializer dut (.pix_clk, .pix_rst_n(prst_n), .tmds0_i(s0), .tmds1_i(s1), .tmds2_i(s2), .tmds_clk_i(10'b0000011111),
    .ser_clk, .ser_rst_n(srst_n), .serial_o(ser));

  // Sent symbols
  localparam int NS = 400;
  logic [29:0] sent [NS]; int nsent = 0;
  always @(posedge pix_clk) if (prst_n) begin
    logic [29:0] v; v = {10'($urandom), 10'($urandom), 10'($urandom)};
    s0 <= v[9:0]; s1 <= v[19:10]; s2 <= v[29:20];
    if (nsent < NS) sent[nsent] = v;
    nsent++;
  end

  // Serial capture
  logic [3:0] bits [NS*10 + 200]; int nb = 0;
  always @(posedge ser_clk) if (srst_n) begin bits[nb] = ser; nb++; end

  task automatic run(input real ph);
    int off, first, matched, k0;
    shift_req = ph; nsent = 0; nb = 0;
    s0 = 0; s1 = 0; s2 = 0; prst_n = 0; srst_n = 0;
    #50; prst_n = 1; srst_n = 1;
    #(NS * 10 - 200);
    // Alignment: clock channel word 1111100000 in time order (bit 0 first)
    off = -1;
    for (int i = 0; i < 100 && off < 0; i++) begin
      logic [9:0] w;
      for (int b = 0; b < 10; b++) w[b] = bits[i + b][3];
      if (w == 10'b0000011111) off = i;
    end
    check(off >= 0, $sformatf("shift %0.2f: clock pattern not found", ph));
    // Recovered word stream; find the first sent symbol and compare the rest in order
    first = -1; matched = 0;
    for (int k = 0; off >= 0 && k < (nb - off) / 10 - 1; k++) begin
      logic [29:0] w; logic [9:0] c;
      for (int b = 0; b < 10; b++) begin
        w[b] = bits[off + 10*k + b][0]; w[10 + b] = bits[off + 10*k + b][1]; w[20 + b] = bits[off + 10*k + b][2];
        c[b] = bits[off + 10*k + b][3];
      end
      check(c == 10'b0000011111, $sformatf("shift %0.2f: clock word %0d = %b", ph, k, c));
      if (first < 0) begin for (int j = 0; j < 10; j++) if (sent[j] == w && w != 0) begin first = j; k0 = k; end end
      else if (first + (k - k0) < NS) begin
        check(w == sent[first + (k - k0)], $sformatf("shift %0.2f: symbol %0d = %h exp %h", ph, first + (k - k0), w, sent[first + (k - k0)]));
        matched++;
      end
    end
    check(matched > 300, $sformatf("shift %0.2f: only %0d symbols compared", ph, matched));
    $display("serial clock shifted %0.2f ns: %0d symbols recovered in order on 3 channels", ph, matched);
  endtask

  initial begin
    if ($test$plusargs("vcd")) begin $dumpfile("tmds_serializer_tb.vcd"); $dumpvars(0, tmds_serializer_tb); end
    run(0.0);
    run(0.3);
    run(0.77);
    if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED (%0d errors)", errors);
    $finish;
  end
endmodule
