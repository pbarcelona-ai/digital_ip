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
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run(input bit d2);
    int first, k0, matched;
    dual = d2;
    ser_half = d2 ? 2.0 : 1.0;
    nsent = 0;
    ph = 0;
    prst_n = 0;
    srst_n = 0;
    stb = 0;
    words = '0;
    #100;
    rx.word_q.delete();
    rx.words = 0;
    rx.clk_errors = 0;
    rx.since = -1;
    prst_n = 1;
    srst_n = 1;
    #(NS * (d2 ? 28 : 14) - 400);
    check(rx.words > 0, "clock pattern not found");
    check(rx.clk_errors == 0, $sformatf("%0d clock lane words other than 1100011", rx.clk_errors));
    // find the first sent word in the recovered stream, then compare the rest in order
    first = -1;
    matched = 0;
    for (int k = 0; k < rx.word_q.size(); k++) begin
      if (first < 0) begin
        for (int j = 0; j < 10; j++) if (sent[j] == rx.word_q[k]) begin
          first = j;
          k0 = k;
        end
      end
      else if (first + (k - k0) < NS) begin
        check(rx.word_q[k] == sent[first + (k - k0)], $sformatf("%s word %0d = %h exp %h", d2 ? "dual" : "single",
              first + (k - k0), rx.word_q[k], sent[first + (k - k0)]));
        matched++;
      end
    end
    check(matched > NS - 40, $sformatf("only %0d words compared", matched));
    $display("%s link rate: %0d words recovered in order on 4 lanes", d2 ? "dual" : "single", matched);
  endtask
