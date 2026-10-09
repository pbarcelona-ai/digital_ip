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
    if (!c) begin
      errors++;
      if (errors < 30) $display("ERROR @%0t: %s", $time, m);
    end
  endtask

  task automatic run(input real ph);
    int first, matched, k0;
    shift_req = ph;
    nsent = 0;
    s0 = 0;
    s1 = 0;
    s2 = 0;
    prst_n = 0;
    srst_n = 0;
    #50;
    rx.sym_q.delete();
    rx.syms = 0;
    rx.clk_errors = 0;
    rx.since = -1;
    prst_n = 1;
    srst_n = 1;
    #(NS * 10 - 200);
    check(rx.syms > 0, $sformatf("shift %0.2f: clock pattern not found", ph));
    check(rx.clk_errors == 0, $sformatf("shift %0.2f: %0d clock channel symbols other than 0000011111", ph, rx.clk_errors));
    // Recovered symbol stream; find the first sent symbol and compare the rest in order
    first = -1;
    matched = 0;
    for (int k = 0; k < rx.sym_q.size(); k++) begin
      if (first < 0) begin
        for (int j = 0; j < 10; j++) if (sent[j] == rx.sym_q[k] && rx.sym_q[k] != 0) begin
          first = j;
          k0 = k;
        end
      end
      else if (first + (k - k0) < NS) begin
        check(rx.sym_q[k] == sent[first + (k - k0)], $sformatf("shift %0.2f: symbol %0d = %h exp %h", ph,
              first + (k - k0), rx.sym_q[k], sent[first + (k - k0)]));
        matched++;
      end
    end
    check(matched > 300, $sformatf("shift %0.2f: only %0d symbols compared", ph, matched));
    $display("serial clock shifted %0.2f ns: %0d symbols recovered in order on 3 channels", ph, matched);
  endtask
