// ***************
// Filename: tmds_serializer_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the tmds_serializer_tb testbench
//   (tmds_serializer_tb.sv), moved out of it and `included into that module,
//   so they use its signals, parameters and models directly. Tasks, in file
//   order:
//     check  Counts an error and prints the message when the condition is
//            false
//     run
// Date: 2026-10-08
// ***************
  task automatic check(input bit c, input string m);
    if (!c) begin errors++; if (errors < 30) $display("ERROR @%0t: %s", $time, m); end
  endtask

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
