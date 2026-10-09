// ***************
// Filename: lvds_serializer_tests.sv
// Author: FPGA Cores 4 U
// Description: Test tasks of the lvds_serializer_tb testbench
//   (lvds_serializer_tb.sv), moved out of it and `included into that module,
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

  task automatic run(input bit d2);
    int off, first, k0, matched;
    dual = d2; ser_half = d2 ? 2.0 : 1.0;
    nsent = 0; nb = 0; ph = 0; prst_n = 0; srst_n = 0; stb = 0; words = '0;
    #100; prst_n = 1; srst_n = 1;
    #(NS * (d2 ? 28 : 14) - 400);
    off = -1;
    for (int i = 0; i < 60 && off < 0; i++) begin
      logic [6:0] w; for (int b = 0; b < 7; b++) w[6 - b] = bits[i + b][4];
      if (w == 7'b1100011 && bits[i + 7][4] == 1'b1 && bits[i + 6][4] == 1'b1) off = i;
    end
    check(off >= 0, "clock pattern not found");
    first = -1; matched = 0;
    for (int k = 0; off >= 0 && k < (nb - off) / 7 - 1; k++) begin
      logic [27:0] w; logic [6:0] c;
      for (int b = 0; b < 7; b++) begin
        for (int l = 0; l < 4; l++) w[7*l + 6 - b] = bits[off + 7*k + b][l];
        c[6 - b] = bits[off + 7*k + b][4];
      end
      check(c == 7'b1100011, $sformatf("clock word %0d = %b", k, c));
      if (first < 0) begin for (int j = 0; j < 10; j++) if (sent[j] == w) begin first = j; k0 = k; end end
      else if (first + (k - k0) < NS) begin
        check(w == sent[first + (k - k0)], $sformatf("%s word %0d = %h exp %h", d2 ? "dual" : "single", first + (k - k0), w, sent[first + (k - k0)]));
        matched++;
      end
    end
    check(matched > NS - 40, $sformatf("only %0d words compared", matched));
    $display("%s link rate: %0d words recovered in order on 4 lanes", d2 ? "dual" : "single", matched);
  endtask
